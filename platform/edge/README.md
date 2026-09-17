# Kubernetes edge

`platform/edge/` owns the cluster-side components that turn host DNS and the worker edge network into managed HTTPS ingress.

```text
Kubernetes Ingress/Service
          │
          ├──► ExternalDNS ──RFC2136──► host BIND9
          │
          └──► ingress-nginx ◄── 192.168.56.200 ── MetalLB

host Vault ──► VSO ──► TLS + TSIG Kubernetes Secrets
```

## Components

| Path | Responsibility |
|---|---|
| `metallb/` | explicit edge VIP pool |
| `ingress-nginx/` | two-replica host-facing ingress |
| `external-dns/` | `lab.test` record reconciliation |
| `vault-secrets-operator/` | runtime secret delivery from Vault |

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