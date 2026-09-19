# Application

`app/` owns the Java service, container image definition, Kubernetes runtime manifests, probes, resource contract, and application file logging.

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

Each Pod contains the Java application and its Fluent Bit file-log sidecar. The service listens on `9001`. `GET /api/foos?val=<value>` returns `QueryStringValue: <value>` and writes the request to the application log.

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

Releases are identified by registry digest. `chart/` inherits the platform base chart ([`charts/service`](../charts/service/README.md)); `chart/values.yaml` holds this app's settings, and delivery sets the digest on every release.

## Deployment contract

`chart/values.yaml` sets four replicas.

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

Replacement Pods must become Ready before old capacity is intentionally removed.

## Health

| Probe | Path | Role |
|---|---|---|
| startup | `/api/foos?val=startup` | gates readiness/liveness until JVM startup succeeds |
| readiness | `/api/foos?val=ready` | gates Service traffic |
| liveness | `/api/foos?val=liveness` | restarts the container after repeated failure |

Readiness is the traffic decision. A running container is not considered ready until this probe passes.

`/actuator/prometheus` exposes HTTP and JVM metrics to the Git-managed ServiceMonitor. The management web surface is limited to health and Prometheus.

## File logging

```text
Java request thread
      │
      ▼
async Logback appender
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

Logback rotates daily and by size. Retained file history is capped at 1 GiB total. Remote log transport is outside the Java request path.

The platform-level Fluent Bit still collects normal Kubernetes container logs. This sidecar exists for the explicit application file log.
Its tail offset database lives on the Pod's shared volume, so a sidecar restart resumes without replaying the file.

## Chart

| File | Owns |
|---|---|
| `chart/Chart.yaml` | release name, base chart version |
| `chart/values.yaml` | image repository, replicas, placement, probes, resources, security, ingress, metrics, Fluent Bit sidecar |
| `Jenkinsfile` | the call into the platform delivery library |

The image pull Secret is provisioned per environment by [`platform/environment`](../platform/environment/). Do not commit registry credentials.

## Release ownership

Deployment is owned by [`delivery/`](../delivery/README.md). Avoid ad-hoc `kubectl` changes: the next release takes those fields back, and they break the commit + digest release identity.
