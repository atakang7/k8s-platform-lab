# Resource request webhook

This component rejects Deployment CREATE/UPDATE requests when any regular container omits either CPU or memory from `resources.requests`.

Canonical design: [Admission policy](../../docs/06-governance-resilience/admission-policy.md).

## Admission path

```text
Deployment CREATE / UPDATE
           │
           ▼
Kubernetes API server
           │ AdmissionReview v1 · HTTPS
           ▼
resource-requests-webhook
           │ inspect regular containers
      ┌────┴────┐
      │         │
      ▼         ▼
 CPU + RAM   missing either
      │         │
      ▼         ▼
    allow      deny
      │         │
      ▼         ▼
continue     reject write
admission
```

`failurePolicy: Fail` makes the API fail closed for in-scope Deployments if the webhook cannot answer.

## Test

```bash
cd policies/resource-requests-webhook
go test ./...
```

The builder Go version matches `go.mod`. The runtime image is distroless and non-root.

## Helm

Chart:

```text
helm/resource-requests-webhook/
```

It creates the Deployment, ClusterIP Service, serving TLS, and `ValidatingWebhookConfiguration`. The Service exposes `443` and targets the webhook HTTPS listener on `8443`.

The release namespace and Kubernetes system namespaces are excluded to prevent self-installation/system deadlocks.

Example install after the image and registry pull Secret exist:

```bash
helm upgrade --install resource-requests-webhook \
  helm/resource-requests-webhook \
  --namespace policy-system \
  --create-namespace \
  --set image.repository=docker.io/atakangul/resource-requests-webhook \
  --set image.tag=<published-tag>
```

## Verify

Use `kubectl apply --dry-run=server` so the real API server, Service/TLS path, and admission code execute without persisting test Deployments.

```text
CPU + memory present  ──► accepted
CPU missing           ──► rejected
memory missing        ──► rejected
existing app manifest ──► accepted
```
