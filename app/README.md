# Application

`app/` owns the Java service, container image definition, Kubernetes runtime settings, probes, resource contract, and application logging.

## Request path

```text
app.lab.test
        │
        ▼
 ingress-nginx
        │
        ▼
sample-java-app Service :80
        │ targetPort :9001
        ▼
   ┌────┴────┐
   │         │
   ▼         ▼
node-2     node-3
2 Pods     2 Pods
```

Each Pod contains the Java application and its Fluent Bit file-log sidecar. The service listens on `9001`. `GET /api/foos?val=<value>` returns `QueryStringValue: <value>` and records the request through the normal application logger.

## Image

Local application checks:

```bash
cd app
./mvnw test
./mvnw package
```

Full container contract from repository root:

```bash
make container-validate
```

`Dockerfile` is multi-stage. The final image contains the application JAR and Java runtime, not Maven, source code, or compiler tooling. The runtime process uses UID/GID `10001` and does not require root.

The app version is `version` in `chart/Chart.yaml`; raise it in every pull request that changes the app. CI publishes the image and chart as that version, and releases pin the image digest. `chart/` inherits the platform base chart ([`charts/service`](../charts/service/README.md)); `chart/values.yaml` holds this app's settings, and delivery sets the digest on every release.

## Deployment contract

`chart/values.yaml` is the prod release: four replicas at `app.lab.test`. `chart/values-dev.yaml` and `chart/values-stage.yaml` run one replica each at `app-dev` and `app-stage`, because all three environments share the lab cluster.

```text
sample-java-app · replicas 4
          │
          ├── worker-only node affinity
          └── topology spread · hostname · maxSkew 1
                          │
                 ┌────────┴────────┐
                 ▼                 ▼
              node-2            node-3
              2 Pods            2 Pods
```

Each Pod contains the Java app and a Fluent Bit sidecar. Both containers declare CPU and memory requests/limits and use non-root security settings.

The stable rollout strategy is:

```text
maxUnavailable: 0
maxSurge:       4
```

Replacement Pods must become Ready before old capacity is intentionally removed. Voluntary disruptions are bounded by a PodDisruptionBudget with `minAvailable: 2`, so maintenance cannot intentionally evict more than half of the service at once.

## Health and shutdown

Health traffic never calls the business endpoint.

| Probe | Path | Role |
|---|---|---|
| startup | `/actuator/health/liveness` | gives the JVM up to 120 seconds to start before liveness/readiness take over |
| readiness | `/actuator/health/readiness` | controls whether the Pod receives Service traffic |
| liveness | `/actuator/health/liveness` | restarts a process whose application context is no longer live |

Spring's Kubernetes probe groups are enabled explicitly. On SIGTERM the application uses graceful shutdown with a 20-second Spring shutdown phase, allowing in-flight requests to finish before the container exits.

`/actuator/prometheus` exposes HTTP and JVM metrics to the Git-managed ServiceMonitor. The management web surface is limited to health and Prometheus.

## Logging

```text
                         ┌──► stdout ──► Kubernetes container log
Java application logger ─┤
                         └──► async file appender
                                  │
                                  ▼
                         /var/log/app/app.log
                                  │ shared emptyDir
                                  ▼
                         Fluent Bit sidecar
                                  │
                                  ▼
                            Elasticsearch
```

The console stream preserves the normal Kubernetes logging path. The file appender exists for the explicit sidecar requirement; it rotates daily and by size, with retained file history capped at 1 GiB. Remote log transport stays outside the Java request path.

The sidecar's tail offset database lives on the Pod's shared volume, so a sidecar restart resumes from its recorded position instead of replaying the whole file.

## Chart

| File | Owns |
|---|---|
| `chart/Chart.yaml` | release name, base chart version |
| `chart/values.yaml` | image repository, replicas, placement, probes, resources, security, ingress, metrics, Fluent Bit sidecar |
| `chart/values-<environment>.yaml` | dev and stage overrides |
| `Jenkinsfile` | the call into the platform delivery library |

The image pull Secret is provisioned per environment by [`platform/environment`](../platform/environment/). Do not commit registry credentials.

## Release ownership

Deployment is owned by [`delivery/`](../delivery/README.md). Avoid ad-hoc `kubectl` changes: the next release takes those fields back, and they break the commit + digest release identity.
