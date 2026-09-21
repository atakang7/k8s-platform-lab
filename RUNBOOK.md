# Runbook

Run from the repository root.

```bash
make cluster-up
make cluster-validate
```

```bash
make edge-up
```

On the first build:

```bash
make edge-validate
```

On later runs:

```bash
make edge-smoke
```

Before the first `make jenkins-up`, provide any CI credentials that are not already in Vault:

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

```bash
make jenkins-up
make environment-up
```

```bash
make observability-up
make observability-smoke
```

Wait for Jenkins to publish the application release into `state/dev.yaml`, then:

```bash
make policies-up
make policies-smoke
```

```bash
make e2e-validate
```

Useful access:

```bash
make endpoints
make credentials
```
