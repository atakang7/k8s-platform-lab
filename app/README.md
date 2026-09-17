# Application

`app/` owns the Java service, container image definition, Kubernetes runtime manifests, probes, resource contract, and application file logging.

Canonical runtime design: [04 — Application runtime](../docs/04-application-runtime/README.md).

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

Production releases are identified by registry digest, not by the image value committed in `k8s/deployment.yaml`. CI publishes the digest; CD renders the Deployment with that digest and verifies the live value after rollout.

## Deployment contract

`k8s/deployment.yaml` maintains four replicas.

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

## File logging

```text
Java request thread
      │
      ▼
async Logback appender
      │
      ▼
/var/log/app/application.log
      │ shared emptyDir
      ▼
Fluent Bit sidecar
      │
      ▼
Elasticsearch
```

Logback rotates daily and by size. Retained file history is capped at 1 GiB total. Remote log transport is outside the Java request path.

The platform-level Fluent Bit still collects normal Kubernetes container logs. This sidecar exists for the explicit application file log.

## Private registry

`k8s/registry-secret.yaml` tells Vault Secrets Operator to materialize `secret/runtime/dockerhub` as the `dockerhub-registry` pull Secret.

Bootstrap the application Vault identity after Vault and VSO are healthy:

```bash
./app/k8s/bootstrap-registry-auth.sh
```

Do not commit registry credentials.

## Manifests

| File | Owns |
|---|---|
| `k8s/deployment.yaml` | replicas, placement, probes, resources, security, sidecar |
| `k8s/service.yaml` | `:80` → application `:9001` |
| `k8s/ingress.yaml` | `app.lab.test` + wildcard TLS |
| `k8s/fluent-bit-config.yaml` | application file-log shipping |
| `k8s/registry-secret.yaml` | Vault-backed Docker Hub pull Secret |
| `k8s/vault-connection.yaml` | application namespace Vault connection |

## Release ownership

Normal deployment is owned by [`delivery/`](../delivery/README.md). Avoid ad-hoc `kubectl set image` changes for production releases; they break the Git-SHA + image-digest release identity.
