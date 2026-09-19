# Resource request webhook

This component rejects Deployment CREATE/UPDATE requests when any regular or init container omits a non-zero CPU or memory value from `resources.requests`.

Lifecycle and install: [policies/README.md](../README.md).

## Admission path

```text
Deployment CREATE / UPDATE
           │
           ▼
Kubernetes API server
           │ AdmissionReview v1 · HTTPS
           ▼
resource-requests-webhook
           │ validate resource + operation
           │ inspect containers + init containers
      ┌────┴────┐
      │         │
      ▼         ▼
 CPU + RAM   missing either
      │         │
      ▼         ▼
    allow      deny
```

The handler validates that it received the expected `apps/v1` Deployment CREATE/UPDATE request instead of relying only on webhook registration to route correctly. `failurePolicy: Fail` makes the API fail closed for in-scope Deployments if the webhook cannot answer.

## Test

```bash
cd policies/resource-requests-webhook
go test ./...
```

Tests cover regular containers, init containers, wrong resources, unsupported operations, and empty admission objects.

## Helm

Chart:

```text
helm/resource-requests-webhook/
```

It creates the Deployment, ClusterIP Service, private serving CA/certificate, and `ValidatingWebhookConfiguration`. The Service exposes `443` and targets the webhook HTTPS listener on `8443`.

The policy requires the environment label and explicitly excludes its own release namespace plus Kubernetes system namespaces by `kubernetes.io/metadata.name`.

Example install after publishing the image:

```bash
helm upgrade --install resource-requests-webhook \
  helm/resource-requests-webhook \
  --namespace policy-system \
  --create-namespace \
  --set image.repository=docker.io/atakangul/resource-requests-webhook \
  --set image.digest=sha256:<published-digest>
```

## Verify

`policies/bin/smoke` uses `kubectl apply --dry-run=server`, so the real API server, Service/TLS path, and admission code execute without persisting test Deployments.

```text
regular CPU + memory present ──► accepted
regular CPU missing          ──► rejected
regular memory missing       ──► rejected
invalid init container       ──► rejected
```
