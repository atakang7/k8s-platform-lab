# Stage 6 — Admission policy

This stage enforces one deployment invariant at Kubernetes admission time: every regular container in a Deployment must explicitly request both CPU and memory.

## Admission flow

```text
kubectl / controller
       │
       │ CREATE or UPDATE Deployment
       ▼
╔══════════════════════════════════════╗
║ Kubernetes API server               ║
╚══════════════════╤═══════════════════╝
                   │ AdmissionReview v1
                   │ HTTPS
                   ▼
        ┌──────────────────────────┐
        │ resource-requests-       │
        │ webhook                  │
        │ policy-system            │
        └────────────┬─────────────┘
                     │ decode Deployment
                     ▼
        ┌──────────────────────────┐
        │ for each regular         │
        │ container                │
        │                          │
        │ CPU request present?     │
        │ memory request present?  │
        └────────────┬─────────────┘
                     │
            ┌────────┴────────┐
            │                 │
            ▼                 ▼
      both present       either missing
            │                 │
            ▼                 ▼
         ALLOW              DENY
                              │
                              ▼
        container "<name>" must specify
        both CPU and memory requests
```

The API server persists the object only after the admission response allows it.

## Why admission control

Kubernetes scheduling uses resource requests, but Kubernetes does not automatically require every Deployment author to declare both CPU and memory requests in the exact way this platform requires.

The webhook keeps that rule at the API boundary. The same policy applies whether the Deployment comes from Jenkins, `kubectl`, another controller, or a future deployment system.

This policy is deliberately narrow. `ResourceQuota`, `LimitRange`, PriorityClass, PodDisruptionBudget, and HPA solve different problems and remain separate mechanisms.

## Implementation

The service is a small Go HTTPS server under `policies/resource-requests-webhook/`.

It exposes:

| Path | Purpose |
|---|---|
| `/validate` | Kubernetes AdmissionReview endpoint |
| `/healthz` | liveness/readiness target |

The service handles `admission.k8s.io/v1`, decodes Deployments, inspects `spec.template.spec.containers`, and returns an explicit allow/deny AdmissionResponse.

Unit tests cover valid and invalid request combinations.

```bash
cd policies/resource-requests-webhook
go test ./...
```

## Runtime layout

```text
                         policy-system

        ┌────────────────────────────────────┐
       /                                    /│
      /  Deployment · non-root distroless  / │
     └─────────────────┬──────────────────┘  │
                       │ :8443 HTTPS          │
                       ▼                      │
             ┌───────────────────┐            │
             │ ClusterIP Service │            │
             │ :443 → :8443      │            │
             └─────────┬─────────┘            │
                       │                      │
                       ▼                      │
          ValidatingWebhookConfiguration     │
          caBundle + /validate               │
```

The Helm chart creates serving TLS for the Kubernetes service DNS names and places the matching CA bundle in the webhook configuration.

The webhook Pod runs non-root with a read-only root filesystem and no privilege escalation.

## Failure behavior

`failurePolicy: Fail` is intentional.

```text
in-scope Deployment
       │
       ▼
webhook reachable?
   │           │
  yes          no
   │           │
   ▼           ▼
policy       request
result       rejected
```

A policy outage therefore fails closed for in-scope Deployment changes instead of silently bypassing enforcement.

System namespaces and the webhook release namespace are excluded. This prevents a broken admission dependency from blocking Kubernetes system workloads or deadlocking the webhook's own installation/update path.

## Installation strategy

The webhook image is built and published before Helm reconciliation. The private registry pull Secret must already exist in `policy-system`.

```bash
helm upgrade --install resource-requests-webhook \
  policies/resource-requests-webhook/helm/resource-requests-webhook \
  --namespace policy-system \
  --create-namespace \
  --set image.repository=docker.io/atakangul/resource-requests-webhook \
  --set image.tag=<published-tag>
```

For a production release path, prefer an immutable image reference rather than an unqualified mutable tag.

## Verification strategy

Use server-side dry-run so the real API server and admission chain execute without leaving test Deployments in the cluster.

```text
valid CPU + memory      → ACCEPT
CPU missing             → REJECT
memory missing          → REJECT
existing application    → ACCEPT
```

The existing application passes because both the Java container and the Fluent Bit sidecar declare CPU and memory requests.

## Source paths

`policies/resource-requests-webhook/cmd/webhook/` owns admission logic and tests. `policies/resource-requests-webhook/Dockerfile` owns the runtime image. `policies/resource-requests-webhook/helm/` owns TLS, Service, Deployment, and webhook registration.