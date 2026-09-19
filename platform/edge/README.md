# Kubernetes edge

`platform/edge/` owns the cluster-side components that turn host DNS and the worker edge network into managed HTTPS ingress.

```text
DNS CONTROL

Kubernetes Ingress / Service metadata
              │
              ▼
          ExternalDNS
              │ signed RFC2136 + TSIG
              ▼
          host BIND9

SECRET DELIVERY

host Vault ──► Vault Secrets Operator ──► TLS + TSIG Kubernetes Secrets

TRAFFIC EDGE

MetalLB ── assigns + L2-advertises ──► ingress Service · 192.168.56.200
                                               │
                                               ▼
                                      ingress-nginx ×2
                                               │
                                               ▼
                                        managed Services
```

## Components

| Path | Responsibility |
|---|---|
| `metallb/` | explicit edge VIP pool and L2 advertisement |
| `ingress-nginx/` | two-replica host-facing ingress |
| `external-dns/` | `lab.test` record reconciliation |
| `vault-secrets-operator/` | runtime secret delivery from Vault |
| `health/` | retained DNS, TLS, and ingress health endpoint |

MetalLB automatic allocation is disabled. ingress-nginx explicitly owns `192.168.56.200`.

## Reconcile

Do not install these charts independently during normal operation. Use the owning edge orchestrator:

```bash
make edge-up
make edge-smoke
```

Full integration check:

```bash
make edge-validate
```

Values and manifests in this directory are desired state. Manual Helm changes are temporary diagnostics only.

Full architecture: [02 — Edge and trust](../../docs/02-edge-trust/README.md).
