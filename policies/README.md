# Policies

`policies/` owns admission controls that reject invalid Kubernetes desired state before it is persisted.

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
           │ inspect containers + init containers
      ┌────┴────┐
      │         │
      ▼         ▼
 CPU + RAM   missing either
      │         │
      ▼         ▼
    allow      deny
```

The webhook applies only to namespaces carrying `delivery.lab.test/environment`. The release namespace and Kubernetes system namespaces are also excluded explicitly by namespace name, so accidentally adding the environment label cannot deadlock the webhook or core control-plane workloads.

`failurePolicy: Fail` makes in-scope Deployment writes fail closed when the webhook cannot answer.

## Build and test

```bash
cd policies/resource-requests-webhook
go test ./...
```

The builder and distroless runtime bases are pinned by digest. The resulting webhook image is deployed only by immutable digest.

## Deploy

Delivery builds, scans and publishes the image (`resource-requests-webhook/Jenkinsfile`) and records its digest in `state/dev.yaml`. It reaches `stage` and `prod` by pull request, like any service ([delivery](../delivery/README.md)). Admission policy is cluster-wide, so the operator installs the digest of one environment, `prod` by default:

```bash
make policy-up POLICY=resource-requests-webhook                   # state/prod.yaml
make policy-up POLICY=resource-requests-webhook ENVIRONMENT=dev   # state/dev.yaml
```

`make policies-up` reconciles every registered policy. Helm waits for readiness and rolls a failed upgrade back.

### Serving TLS ownership

The Helm release owns one private serving CA and certificate in `resource-requests-webhook-tls`.

```text
first install ──► generate CA + service certificate ──► Secret + caBundle
upgrade       ──► reuse existing Secret              ──► stable caBundle
delete Secret ──► next reconciliation generates a new serving identity
```

The certificate covers the webhook Service DNS names. Policy smoke verifies that the Secret CA and `ValidatingWebhookConfiguration.caBundle` are identical.

## Verify

```bash
make policy-smoke POLICY=resource-requests-webhook
make policies-smoke
```

The smoke contract verifies rollout, immutable image identity, replica spread, serving TLS, fail-closed webhook registration, namespace scope, and real server-side admission decisions for regular and init containers.

This webhook enforces one invariant only. ResourceQuota, LimitRange, PriorityClass, PDBs, and autoscaling remain separate Kubernetes controls.
