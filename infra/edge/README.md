# Edge orchestration

`infra/edge/` is the operator entry point for the host-side trust and Kubernetes edge bootstrap.

```text
make edge-up
     │
     ├──► host Ansible: Vault / BIND9 / CA / resolver
     │
     ├──► Vault bootstrap identities
     │
     ├──► Kubernetes edge charts/resources
     │
     └──► DNS + TLS secret delivery
```

Shared addresses are in `config.env`. Pinned component versions are in `versions.env`.

## First bootstrap

```bash
make edge-up
VAULT_INIT_OUTPUT=/secure/path/vault-init.json make vault-init
make vault-unseal
make edge-up
```

Vault initialization and unseal are intentionally explicit operator actions. Init output and root/unseal material stay outside Git.

## Normal operation

```bash
make edge-up
make edge-smoke
```

Deep verification:

```bash
make edge-validate
```

After host reboot:

```bash
make vault-unseal
make edge-up
```

## Flow

```text
Vault ──► Vault Agent ──► BIND TSIG runtime file
   │
   └────► VSO identities ──► cluster Secrets

Kubernetes metadata ──► ExternalDNS ──RFC2136──► BIND9

MetalLB 192.168.56.200 ──► ingress-nginx ──► managed Services
```

`bin/up` coordinates state; `lib/` contains narrow Vault/Kubernetes helpers. Do not bypass this layer with persistent manual Helm or host-service changes.