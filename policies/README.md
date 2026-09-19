# Policies

`policies/` owns admission controls that protect Kubernetes desired state before it is persisted.

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

## Deploy one policy

Deployments are non-interactive and use immutable image digests. Supply the
digest on the first install; subsequent runs reuse the installed digest unless
an explicit replacement is supplied.

```bash
RESOURCE_REQUESTS_WEBHOOK_IMAGE_DIGEST=sha256:<published-digest> \
  make policy-up POLICY=resource-requests-webhook

# Idempotent reconciliation after the first successful install.
make policy-up POLICY=resource-requests-webhook
```

`make policies-up` deploys every registered policy. Failed Helm upgrades roll
back automatically instead of leaving a partially reconciled admission path.

## Verify

Each policy owns a smoke contract. It checks rollout and registration, then
uses server-side dry-run so the real admission chain executes without
persisting test workloads.

```bash
make policy-smoke POLICY=resource-requests-webhook
make policies-smoke
```

```text
valid Deployment       ──► accepted
missing CPU request    ──► rejected
missing memory request ──► rejected
existing app manifest  ──► accepted
```

This webhook enforces one invariant only. ResourceQuota, LimitRange, PriorityClass, PDBs, and autoscaling remain separate Kubernetes controls.
