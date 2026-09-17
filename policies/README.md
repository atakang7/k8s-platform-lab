# Policies

`policies/` owns admission controls that protect Kubernetes desired state before it is persisted.

Canonical design: [Admission policy](../docs/06-governance-resilience/admission-policy.md).

## Resource request policy

The current policy is the custom validating webhook under `resource-requests-webhook/`.

```text
Deployment CREATE / UPDATE
           │
           ▼
Kubernetes API server
           │ AdmissionReview v1 · HTTPS
           ▼
resource-requests-webhook
           │
      ┌────┴────┐
      │         │
      ▼         ▼
all regular   CPU or memory
containers    request missing
valid            │
      │          ▼
      ▼         deny
     allow        │
      │           ▼
      ▼       reject write
continue
admission
```

The policy applies on CREATE and UPDATE. `failurePolicy: Fail` rejects an in-scope write when the webhook cannot be reached instead of silently bypassing validation.

`policy-system` and Kubernetes system namespaces are excluded so the webhook cannot deadlock its own installation or core control-plane objects.

## Build and test

```bash
cd policies/resource-requests-webhook
go test ./...
```

The runtime is a static Go binary on a distroless non-root image.

## Install

After the webhook image exists and the `policy-system` namespace can pull it:

```bash
helm upgrade --install resource-requests-webhook \
  policies/resource-requests-webhook/helm/resource-requests-webhook \
  --namespace policy-system \
  --create-namespace \
  --set image.repository=docker.io/atakangul/resource-requests-webhook \
  --set image.digest=sha256:<published-digest>
```

The chart creates the Deployment, Service, serving TLS, and `ValidatingWebhookConfiguration`.

## Verify

Use server-side dry-run so the real admission chain executes without persisting test workloads.

```text
valid Deployment       ──► accepted
missing CPU request    ──► rejected
missing memory request ──► rejected
existing app manifest  ──► accepted
```

This webhook enforces one invariant only. ResourceQuota, LimitRange, PriorityClass, PDBs, and autoscaling remain separate Kubernetes controls.
