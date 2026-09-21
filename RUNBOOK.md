# Runbook

Run from the repository root.

## Build the environment

```bash
make cluster-up
make cluster-validate

make edge-up
make edge-validate
make edge-smoke

make jenkins-up
make environment-up

make observability-up
make observability-smoke

make policies-up
make policies-smoke

make e2e-validate
```

Before the first `make jenkins-up`:

```bash
export GITHUB_USERNAME=...
export GITHUB_TOKEN=...
export DOCKERHUB_USERNAME=...
export DOCKERHUB_TOKEN=...
export COSIGN_PASSWORD=...
export COSIGN_PRIVATE_KEY="$(cat cosign.key)"

vault kv put secret/runtime/dockerhub username=... token=...
```

## Inspect

```bash
make endpoints
make credentials
```

## Recover

Host reboot or sealed Vault:

```bash
make edge-up
```

Manual Vault unseal:

```bash
make vault-unseal
```

Reapply cluster provisioning:

```bash
vagrant provision node-3
make cluster-validate
```

After Jenkins configuration or agent changes:

```bash
make jenkins-up
```

## Roll back a release

Restore a known healthy environment state and send it through the normal PR path:

```bash
git checkout <healthy-environment-tag> -- state/<environment>.yaml
git diff -- state/<environment>.yaml
```

Do not use an ad-hoc `helm rollback` as the permanent fix; Git is the desired state.

## Stop / destroy

Stop edge services but keep host Vault/DNS state:

```bash
make edge-down
```

Destroy the VMs:

```bash
make destroy
```

Host Vault, BIND9, and CA state are retained.
