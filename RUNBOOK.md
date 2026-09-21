# Runbook

Operator procedures for the Lab lab. Run commands from the repository root.

For architecture, see [README.md](README.md). For release behavior, see [DELIVERY.md](DELIVERY.md).

## Contents

1. [Fresh environment](#1-fresh-environment)
2. [Inspect the platform](#2-inspect-the-platform)
3. [Validate](#3-validate)
4. [Common recovery](#4-common-recovery)
5. [Release rollback](#5-release-rollback)
6. [Stop and destroy](#6-stop-and-destroy)

Persistent changes follow one rule: change Git, run the owning reconciliation command, then run its check.

---

## 1. Fresh environment

### Kubernetes foundation

```bash
make cluster-up
make cluster-validate
```

### Edge, DNS, TLS and Vault

```bash
make edge-up
make edge-validate
make edge-smoke
```

`edge-validate` is the deeper integration check. Normal later reconciliations usually need only `edge-up` and `edge-smoke`.

### Jenkins credentials

Before the first `make jenkins-up`, provide any CI credentials that do not already exist in Vault:

```bash
export GITHUB_USERNAME=...
export GITHUB_TOKEN=...
export DOCKERHUB_USERNAME=...
export DOCKERHUB_TOKEN=...
export COSIGN_PASSWORD=...
export COSIGN_PRIVATE_KEY="$(cat cosign.key)"
```

Runtime image-pull credentials are stored separately:

```bash
vault kv put secret/runtime/dockerhub username=... token=...
```

### Platform

```bash
make jenkins-up
make environment-up
make observability-up
make observability-smoke
make policies-up
make policies-smoke
```

`make environment-up` prepares only the environment selected by `clusterEnvironment` in `environments.yaml`.

### Final proof

```bash
make e2e-validate
```

---

## 2. Inspect the platform

Show operator-facing endpoints:

```bash
make endpoints
```

Show Jenkins and Grafana login credentials already materialized in Kubernetes:

```bash
make credentials
```

Useful endpoints:

```text
Jenkins     https://jenkins.lab.test
Grafana     https://observability.lab.test/grafana/
Prometheus  https://observability.lab.test/prometheus/
```

---

## 3. Validate

### Foundation

```bash
make cluster-validate
make container-validate
```

### Edge

```bash
make edge-smoke
make edge-validate
```

### Platform

```bash
make observability-smoke
make policies-smoke
```

### End to end

```bash
make e2e-validate
```

When a validation fails:

```text
identify owning subsystem
        │
        ▼
fix desired state in Git
        │
        ▼
run owning reconcile command
        │
        ▼
rerun failed validation
```

Validation should not repair platform state itself.

---

## 4. Common recovery

### Host reboot / Vault sealed

Normal recovery:

```bash
make edge-up
```

The edge reconciler reuses the retained operator state and unseals Vault when needed.

Manual unseal is available when diagnosing Vault directly:

```bash
make vault-unseal
```

Vault init/unseal material is retained outside Git under the operator state path configured by the edge layer.

### Reapply Kubernetes provisioning

For an existing cluster:

```bash
vagrant provision node-3
make cluster-validate
```

Permanent VM or Kubernetes fixes belong in the Ansible roles before reprovisioning.

### Jenkins configuration changed

```bash
make jenkins-up
```

The reconciliation refreshes Jenkins configuration and removes existing agent Pods so new work uses the current templates.

### Policy changed

All policies:

```bash
make policies-up
make policies-smoke
```

One policy:

```bash
make policy-up POLICY=resource-requests-webhook
make policy-smoke POLICY=resource-requests-webhook
```

---

## 5. Release rollback

Runtime deployment failures already roll back the Helm release, but Git remains the desired state.

For a deliberate rollback, restore a known healthy environment state in Git:

```bash
git checkout <healthy-environment-tag> -- state/<environment>.yaml
git diff -- state/<environment>.yaml
```

Commit the restored state and send it through the normal pull-request path.

Example healthy tags:

```text
dev-2026.09.21.5
stage-...
prod-...
```

Do not perform a permanent rollback with an ad-hoc `helm rollback`; the next deploy would reconcile back to Git.

---

## 6. Stop and destroy

Stop the edge stack while retaining host Vault/DNS state:

```bash
make edge-down
```

Destroy the Vagrant VMs:

```bash
make destroy
```

`make destroy` does **not** remove the retained host-side Vault, BIND9 or CA state.

To rebuild the VMs afterward:

```bash
make cluster-up
make cluster-validate
make edge-up
```
