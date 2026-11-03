# Bring up the lab

Use an Ubuntu x86_64 host with virtualization enabled. The default Vagrant plan needs 10 GiB RAM for its VMs, plus host overhead.

## Create the cluster

Run from the repository root:

```sh
make prerequisites
make cluster-up
make cluster-validate
make edge-up
make edge-validate
```

The first command installs Vagrant, VirtualBox, Ansible, Helm and host utilities. The edge step creates the host CA, BIND9 and Vault.

## Add CI credentials

```sh
cp .env.example .env
${EDITOR:-vi} .env
set -a; source .env; set +a
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_TOKEN="$(jq -r .root_token ~/.local/share/lab-operator/vault-init.json)"
```

Run the four `vault kv put` commands near the top of [.env.example](../../.env.example). They write GitHub, Docker Hub, Cosign and runtime registry credentials into Vault.

## Install the platform

```sh
make jenkins-up
make environment-up
make observability-up
make observability-smoke
```

After Jenkins publishes an application digest to `state/dev.yaml`, run:

```sh
make policies-up
make policies-smoke
make e2e-validate
```

See [known issues](../reference/known-issues.md) before exposing the edge network.
