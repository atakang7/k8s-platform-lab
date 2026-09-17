# Application

`app/` contains the Java service, container definition, runtime logging, and Kubernetes manifests.

## Runtime contract

- Java 11 Spring Boot application.
- Listens on `9001`.
- `GET /api/foos?val=<value>` returns `QueryStringValue: <value>` and writes the request to the application log.
- Runs as non-root UID/GID `10001`.
- Production images are deployed by immutable registry digest.

```text
request
   │
   │ HTTPS
   │
app.lab.test
   │
 ingress-nginx
   │
 sample-java-app Service
   │
┌──┴───────────────────────────────────────────┐
│ Deployment · 4 replicas                     │
│                                             │
│ worker node-2             worker node-3     │
│ app + Fluent Bit          app + Fluent Bit  │
│ app + Fluent Bit          app + Fluent Bit  │
└──────────────────────────────────────────────┘
```

The Deployment excludes the control plane and uses topology spread with `maxSkew: 1`. Rolling updates use `maxUnavailable: 0`; a rollout must keep the previous replicas available while replacement Pods become ready.

## Build

Local application build:

```bash
cd app
./mvnw test
./mvnw package
```

Container validation from the repository root:

```bash
make container-validate
```

The Dockerfile is multi-stage. The runtime image contains the JAR and Java runtime, not Maven, source code, or the compiler.

## Kubernetes manifests

| File | Purpose |
|---|---|
| `k8s/deployment.yaml` | Four application Pods, probes, resources, topology spread, Fluent Bit sidecar |
| `k8s/service.yaml` | ClusterIP service on port 80 to application port 9001 |
| `k8s/ingress.yaml` | `app.lab.test` over the shared wildcard TLS certificate |
| `k8s/fluent-bit-config.yaml` | Reads the application file log and ships it to Elasticsearch |
| `k8s/registry-secret.yaml` | VSO declaration for the private Docker Hub pull secret |
| `k8s/vault-connection.yaml` | Vault connection used by the application namespace |

Do not treat the image value committed in `deployment.yaml` as the release identifier. CD renders the manifest with the immutable digest produced by CI and asserts the running Deployment matches that digest.

## Health

The same lightweight endpoint is used with distinct values:

| Probe | Request |
|---|---|
| startup | `/api/foos?val=startup` |
| readiness | `/api/foos?val=ready` |
| liveness | `/api/foos?val=liveness` |

## Logging

The application writes `/var/log/app/application.log` through an asynchronous Logback appender. Files rotate daily and by size, with the configured history capped at 1 GiB total.

An `emptyDir` is shared with the per-Pod Fluent Bit sidecar:

```text
Java process ── file log ── shared volume ── Fluent Bit ── Elasticsearch
```

This keeps application logging asynchronous and separates log transport from the Java process.

## Deployment

Normal deployment is owned by [`delivery/`](../delivery/README.md). Do not manually replace the production image tag with an ad-hoc `kubectl set image`; the delivery pipeline carries the source commit and immutable image digest together.