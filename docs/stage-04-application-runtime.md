# Stage 4 — Application runtime

This stage defines how the Java service runs inside Kubernetes and how traffic, health, rollout, resource, and log behavior are enforced.

## Runtime layout

```text
                         app.lab.test
                                │
                                ▼
                    ┌──────────────────────┐
                    │ ingress-nginx        │
                    │ wildcard TLS         │
                    └──────────┬───────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │ sample-java-app      │
                    │ ClusterIP :80        │
                    └──────────┬───────────┘
                               │ targetPort 9001
                 ┌─────────────┴─────────────┐
                 │                           │
                 ▼                           ▼
      ┌──────────────────────┐    ┌──────────────────────┐
      │ node-2               │    │ node-3               │
      │                      │    │                      │
      │ app + Fluent Bit     │    │ app + Fluent Bit     │
      │ app + Fluent Bit     │    │ app + Fluent Bit     │
      └──────────────────────┘    └──────────────────────┘
```

The Deployment runs four replicas. The control plane is excluded with required node affinity. Topology spread keeps replica skew at most one across worker hostnames.

## Container contract

The service listens on port `9001` and exposes:

```text
GET /api/foos?val=<value>
        │
        ▼
QueryStringValue: <value>
```

The runtime image is built in multiple stages. The final image contains the Java runtime and application JAR, not Maven, compiler tooling, or source files. The application runs as UID/GID `10001` and does not require root.

Local verification:

```bash
make container-validate
```

## Pod contract

Each application Pod contains two regular containers:

```text
┌───────────────────────────────────────────────┐
│ sample-java-app Pod                           │
│                                               │
│  ┌──────────────────┐   shared emptyDir       │
│  │ Java app         │ ───────────────────┐    │
│  │ :9001            │   /var/log/app     │    │
│  └──────────────────┘                    │    │
│                                          ▼    │
│                               ┌────────────────┐
│                               │ Fluent Bit     │
│                               │ sidecar        │
│                               └───────┬────────┘
└───────────────────────────────────────┼────────┘
                                        ▼
                                  Elasticsearch
```

Both containers declare CPU and memory requests and limits. This is required by the admission policy in Stage 6.

The application container uses non-root security settings and no privilege escalation. The Fluent Bit sidecar follows the same non-root boundary.

## Health strategy

One lightweight endpoint is used with distinct query values so probe traffic remains visible in logs.

| Probe | Path | Purpose |
|---|---|---|
| startup | `/api/foos?val=startup` | gives JVM startup time before liveness enforcement |
| readiness | `/api/foos?val=ready` | controls Service traffic eligibility |
| liveness | `/api/foos?val=liveness` | restarts a stuck process |

The startup probe allows a long initialization window. Readiness is evaluated frequently. Liveness is slower and is not used as a traffic gate.

## Rollout strategy

The stable Deployment uses `RollingUpdate` with:

```text
maxUnavailable = 0
maxSurge       = 4
```

That means replacement capacity is created before an old replica is intentionally removed.

```text
old replica set:   ● ● ● ●
                         │
                         │ create ready replacements first
                         ▼
transition:         ● ● ● ●  ○ ○ ○ ○
                                  │
                                  │ readiness passes
                                  ▼
new replica set:    ○ ○ ○ ○
```

Readiness, not container start, decides when a replacement can receive traffic.

## Image identity

The committed image field in `app/k8s/deployment.yaml` is a source manifest value, not the release identity.

The normal release path is:

```text
CI build
  │
  ▼
registry digest
  │
  ▼
CD renders Deployment locally with that digest
  │
  ▼
kubectl apply
  │
  ▼
rollout wait
  │
  ▼
read live Deployment and assert exact digest
```

Production debugging and rollback should identify a release by both Git commit and immutable image digest.

## Logging strategy

Logback writes `/var/log/app/application.log` asynchronously. Rotation is daily and size-based. Retained file history is capped at 1 GiB total.

The Java process is responsible for producing the file; the sidecar is responsible for transport. A temporary Elasticsearch or network failure therefore does not make application request handling synchronously depend on remote log delivery.

## Secrets

Private image pull credentials originate in Vault and are materialized as the `dockerhub-registry` Kubernetes Secret through VSO. The Deployment references that Secret through `imagePullSecrets`.

## Source paths

`app/Dockerfile` owns the image. `app/src/` owns service and logging behavior. `app/k8s/` owns runtime manifests. `delivery/ansible/` owns release application. [`app/README.md`](../app/README.md) is the folder-level operator reference.