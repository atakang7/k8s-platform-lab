# 04 — Application runtime

This layer defines how the Java service is built into a runtime image and how that image runs inside Kubernetes.

## Request path

```text
https://app.lab.test/api/foos?val=<value>
                         │
                         ▼
                  ingress-nginx
                         │
                         ▼
              sample-java-app Service
                         │
              ┌──────────┴──────────┐
              │                     │
              ▼                     ▼
      ┌────────────────┐    ┌────────────────┐
     / node-2         /│   / node-3         /│
    / 2 app Pods     / │  / 2 app Pods     / │
   └────────────────┘  │ └────────────────┘  │
   │ app + Fluent Bit│ /  │ app + Fluent Bit│ /
   └────────────────┘/   └────────────────┘/
```

The application listens on `9001`. The Service exposes it inside the cluster and ingress-nginx owns external TLS and routing.

## Container build

The Dockerfile separates build tooling from runtime content.

```text
source + pom.xml
      │
      ▼
JDK build stage
  dependency:go-offline
  Maven package
      │
      ▼
application.jar
      │
      ▼
minimal JRE runtime stage
  non-root UID 10001
  immutable base digest
  OCI source/revision labels
```

Dependencies are resolved before application source is copied. Source-only changes can therefore reuse the dependency layer when the Maven descriptor is unchanged.

Both base images are pinned by digest. The runtime stage contains the JRE and application JAR, not Maven, the JDK, or source code.

## Workload shape

The stable Deployment keeps four replicas and excludes the control-plane node.

```text
                   sample-java-app · replicas: 4
                              │
                 topologySpreadConstraints
                     maxSkew: 1
                              │
                 ┌────────────┴────────────┐
                 ▼                         ▼
              node-2                    node-3
              2 Pods                    2 Pods
```

`topologySpreadConstraints` uses the hostname topology and `DoNotSchedule`. Kubernetes must preserve the worker distribution instead of silently packing the entire replica set onto one worker.

## Resource contract

Each Pod contains the Java application and a Fluent Bit sidecar.

| Container | CPU request | Memory request | CPU limit | Memory limit |
|---|---:|---:|---:|---:|
| app | `250m` | `256Mi` | `500m` | `512Mi` |
| Fluent Bit | `50m` | `32Mi` | `100m` | `128Mi` |

These requests are also what the admission layer later enforces as a platform invariant.

## Health model

The service uses separate startup, readiness, and liveness checks even though they call the same lightweight endpoint with different values.

```text
Pod starts
   │
   ▼
startup probe
   │ success
   ▼
readiness probe ──► Service may send traffic
   │
   └──────── liveness probe keeps checking process health
```

The startup probe has a long enough failure budget for JVM startup and prevents liveness from killing a process that is still legitimately booting.

Readiness is what protects traffic. A newly created Pod is not an endpoint until the application responds successfully.

## Rolling update strategy

```text
old ReplicaSet · 4 ready
          │
          │ new release
          ▼
new ReplicaSet may surge by up to 4
          │
          │ new Pods become Ready
          ▼
old Pods are removed
```

`maxUnavailable: 0` prevents the rollout controller from intentionally reducing the ready replica count below the existing desired count during replacement. `maxSurge: 4` lets the new revision be created aggressively when cluster capacity allows.

The normal release path therefore optimizes for availability first. The separate canary strategy in [06 — Governance and resilience](../06-governance-resilience/capacity-release.md) is used when release risk matters more than simple replacement speed.

## Private image authentication

The Deployment references `dockerhub-registry`. That Secret is not committed with credentials.

```text
Vault · secret/runtime/dockerhub
            │
            ▼
Vault Secrets Operator
            │
            ▼
default/dockerhub-registry
            │
            ▼
Pod imagePullSecrets
```

The application namespace receives only the registry material required to pull runtime images.

## Application logging

The Java process writes `/var/log/app/application.log` through an asynchronous Logback appender.

```text
request thread
     │
     ▼
async Logback queue
     │
     ▼
/var/log/app/application.log
     │
     │ shared emptyDir
     ▼
Fluent Bit sidecar
     │
     ▼
Elasticsearch
```

Rotation is both time- and size-bounded. Logs rotate daily and the configured retained history is capped at 1 GiB total. The sidecar reads the shared file read-only.

This makes log transport independent from the application thread and prevents an Elasticsearch/network delay from becoming synchronous request latency.

## Security context

The application image runs as UID/GID `10001`. Kubernetes sets `runAsNonRoot`, blocks privilege escalation, and uses an `fsGroup` for the shared log volume.

The Fluent Bit sidecar also runs non-root with bounded resources.

## Source paths

- [`app/Dockerfile`](../../app/Dockerfile) — build/runtime image contract.
- [`app/k8s/deployment.yaml`](../../app/k8s/deployment.yaml) — replicas, resources, probes, placement, logging sidecar.
- [`app/k8s/service.yaml`](../../app/k8s/service.yaml) — Service routing.
- [`app/k8s/ingress.yaml`](../../app/k8s/ingress.yaml) — external host/path.
- [`app/src/main/resources/logback-spring.xml`](../../app/src/main/resources/logback-spring.xml) — asynchronous rotation policy.
- [`app/k8s/registry-secret.yaml`](../../app/k8s/registry-secret.yaml) — Vault-backed pull secret.

Normal releases are owned by [05 — Delivery](../05-delivery/README.md), not by manual image changes on this Deployment.
