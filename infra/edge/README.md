# Edge orchestration

`infra/edge/` is the operator entry point for the host-side trust and Kubernetes edge bootstrap.

```text
make edge-up
     │
     ├──► host Ansible · Vault / BIND9 / CA / resolver
     ├──► Vault policies + AppRole identities
     ├──► Kubernetes edge charts/resources
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
Vault · edge/dns/tsig
      │
      ├──► Vault Agent ──► BIND9 runtime TSIG key
      └──► VSO ──────────► ExternalDNS TSIG Secret

ExternalDNS ── signed RFC2136 ──► BIND9

Vault · edge/tls/wildcard ──► VSO ──► ingress TLS Secret

MetalLB ── assigns + L2-advertises ──► ingress Service VIP · 192.168.56.200
                                               │
                                               ▼
                                      ingress-nginx controllers
                                               │
                                               ▼
                                         managed Services
```

`bin/up` coordinates state; `lib/` contains narrow Vault/Kubernetes helpers. Do not bypass this layer with persistent manual Helm or host-service changes.
