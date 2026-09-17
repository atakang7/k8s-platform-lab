# Resource request webhook

This component rejects Deployment CREATE/UPDATE requests when any regular container omits either CPU or memory from `resources.requests`.

## Admission path

```text
Deployment request
      │
      ▼
Kubernetes API server
      │ AdmissionReview v1 · HTTPS
      ▼
┌────────────────────────────┐
│ resource-requests-webhook  │
│ /validate                  │
└─────────────┬──────────────┘
              │
       inspect containers
              │
       ┌──────┴──────┐
       ▼             ▼
 CPU + memory     missing either
       │             │
       ▼             ▼
     ALLOW           DENY
```

`failurePolicy: Fail` makes the API fail closed for in-scope Deployments if the webhook cannot answer.

## Test

```bash
cd policies/resource-requests-webhook
go test ./...
```

The builder Go version must match `go.mod`. The runtime image is distroless and non-root.

## Helm

Chart:

```text
helm/resource-requests-webhook/
```

It creates the Deployment, Service, serving TLS, and `ValidatingWebhookConfiguration`. TLS includes the Kubernetes Service DNS names and the CA is inserted into the webhook configuration.

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

Use `kubectl apply --dry-run=server` so the real admission chain executes without persisting test Deployments.

Expected behavior:

```text
CPU + memory present  ──► accepted
CPU missing           ──► rejected
memory missing        ──► rejected
```

Full policy design: [`docs/stage-06-admission-policy.md`](../../docs/stage-06-admission-policy.md).