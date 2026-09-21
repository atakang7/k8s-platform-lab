# Runbook

Run from the repository root.

```bash
make cluster-up
```

```bash
make cluster-validate
```

If cluster validation fails, fix the cluster before continuing.

```bash
make edge-up
```

On a fresh build, run the deep edge check once:

```bash
make edge-validate
```

For normal later reconciliations, `make edge-smoke` is enough:

```bash
make edge-smoke
```

Before the first `make jenkins-up`, make sure the CI credentials exist in Vault. If they do not, provide them:

```bash
export GITHUB_USERNAME=...
export GITHUB_TOKEN=...
export DOCKERHUB_USERNAME=...
export DOCKERHUB_TOKEN=...
export COSIGN_PASSWORD=...
export COSIGN_PRIVATE_KEY="$(cat cosign.key)"
```

The runtime image-pull credential is separate:

```bash
vault kv put secret/runtime/dockerhub username=... token=...
```

Then reconcile Jenkins:

```bash
make jenkins-up
```

Prepare the environment selected by `clusterEnvironment` in `environments.yaml`:

```bash
make environment-up
```

Reconcile observability and verify it:

```bash
make observability-up
make observability-smoke
```

At this point Jenkins must have produced the application release before the final platform proof is meaningful.

Install the admission policies:

```bash
make policies-up
make policies-smoke
```

Then run the full validation:

```bash
make e2e-validate
```

Inspect the platform when needed:

```bash
make endpoints
make credentials
```

After a host reboot, or if Vault is sealed:

```bash
make edge-up
```

Use manual unseal only when diagnosing Vault directly:

```bash
make vault-unseal
```

To reapply cluster provisioning without rebuilding the VMs:

```bash
vagrant provision node-3
make cluster-validate
```

After Jenkins configuration or agent-template changes:

```bash
make jenkins-up
```

To roll back an environment, restore a known healthy state and send it through the normal PR path:

```bash
git checkout <healthy-environment-tag> -- state/<environment>.yaml
git diff -- state/<environment>.yaml
```

Do not use an ad-hoc `helm rollback` as the permanent fix; Git is the desired state.

To stop edge services while keeping host Vault/DNS state:

```bash
make edge-down
```

To destroy the VMs:

```bash
make destroy
```

Host Vault, BIND9, and CA state are retained.
