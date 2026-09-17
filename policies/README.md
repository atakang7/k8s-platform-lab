# Policies

`policies/` contains admission controls that protect runtime configuration before Kubernetes persists it.

## Resource request policy

The current policy is a custom validating admission webhook under `resource-requests-webhook/`.

```text
kubectl / controller
        │
        │ CREATE or UPDATE Deployment
        │
Kubernetes API server
        │
        │ AdmissionReview v1
        │ HTTPS
        │
resource-requests-webhook
        │
        ├─ every regular container has CPU request
        ├─ every regular container has memory request
        │
        ├─ valid   → allow
        └─ invalid → deny
```

The webhook evaluates Deployments on CREATE and UPDATE. It rejects a Deployment when any regular container omits either CPU or memory from `resources.requests`.

The webhook runs in `policy-system`. That namespace, Kubernetes system namespaces, and the webhook's own deployment path are excluded from enforcement so the admission service cannot deadlock its own installation.

`failurePolicy: Fail` is intentional. If the policy service cannot be reached for an in-scope Deployment, Kubernetes rejects the request instead of bypassing the policy.

## Build and test

```bash
cd policies/resource-requests-webhook
go test ./...
```

The container is a static Go binary on a distroless non-root runtime. The builder Go version matches `go.mod`.

Build and publish the webhook image through the same registry authentication boundary used by the platform. The Helm chart accepts the repository and tag through values; production installation should use an immutable published artifact when available.

## Install

The Helm chart is in:

```text
resource-requests-webhook/helm/resource-requests-webhook/
```

It creates:

- the webhook Deployment and ClusterIP Service;
- serving TLS material for the service DNS names;
- a `ValidatingWebhookConfiguration` with the matching CA bundle;
- HTTPS liveness/readiness checks;
- configurable image pull secrets.

Example reconciliation after the image exists:

```bash
helm upgrade --install resource-requests-webhook \
  policies/resource-requests-webhook/helm/resource-requests-webhook \
  --namespace policy-system \
  --create-namespace \
  --set image.repository=docker.io/atakangul/resource-requests-webhook \
  --set image.tag=<published-tag>
```

The private registry secret must exist in `policy-system` before the Pod pulls the image.

## Verify

Use server-side dry-run. It executes admission without leaving test Deployments behind.

A valid Deployment must be accepted. Deployments with only CPU or only memory requests must be rejected with:

```text
container "<name>" must specify both CPU and memory requests
```

The live application manifest is also expected to pass because both the application container and its Fluent Bit sidecar define CPU and memory requests.

## Scope

This policy enforces one invariant only: explicit CPU and memory requests on regular Deployment containers. It does not replace `ResourceQuota`, `LimitRange`, scheduling priority, PodDisruptionBudgets, or autoscaling. Those solve different resource-management problems.