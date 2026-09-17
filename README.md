# Lab Kubernetes Platform

This repository is the source of truth for the infrastructure, Kubernetes platform, application runtime, delivery path, policy controls, and operating procedures. The environment is built from Git-managed configuration; credentials stay outside Git and are delivered from Vault to the consumers that need them.

```text
                              Git + operator inputs
                                       │
                        desired state / credentials
                                       │
                                       ▼
┌──────────────────────────────── HOST ────────────────────────────────┐
│                                                                     │
│  Vault                         BIND9                    local CA      │
│  secret authority              lab.test          trust root   │
│     │                              ▲                         │       │
│     │                              │ RFC2136                 │       │
└─────┼──────────────────────────────┼─────────────────────────┼───────┘
      │                              │                         │
      │ Vault API                    │ DNS control             │ TLS trust
      │                              │                         │
┌─────┼──────────────────────────────┼─────────────────────────┼───────┐
│     ▼                              │                         ▼       │
│  Vault Secrets Operator      ExternalDNS              ingress TLS   │
│                                                                     │
│  MetalLB assigns/advertises 192.168.56.200 to the ingress Service   │
│                                       │                             │
│                                       ▼                             │
│                              ingress-nginx ×2                       │
│                                       │ HTTPS routing               │
│                  ┌────────────────────┼────────────────────┐         │
│                  │                    │                    │         │
│                  ▼                    ▼                    ▼         │
│          sample-java-app          Jenkins            observability  │
│          4 replicas               controller         metrics + logs │
│          node-2 / node-3          node-3 · 0 execs                  │
│                                       │                             │
│                                  CI/CD agents                       │
│                                  node-3                             │
│                                                                     │
│  node-1                    node-2                    node-3          │
│  control plane             worker                    worker          │
│  10.50.0.10                10.50.0.11               10.50.0.12     │
│                            192.168.56.11             192.168.56.12  │
└──────────────────────────── KUBERNETES ──────────────────────────────┘
```

## Documentation

| Layer | Purpose |
|---|---|
| [01 — Foundation](docs/01-foundation/README.md) | machines, kubeadm cluster, networking, storage, resource layout |
| [02 — Edge and trust](docs/02-edge-trust/README.md) | DNS, TLS, Vault, secret delivery, ingress, LoadBalancer edge |
| [03 — Platform services](docs/03-platform-services/README.md) | Jenkins and observability services |
| [04 — Application runtime](docs/04-application-runtime/README.md) | container build, probes, placement, rollout, logging |
| [05 — Delivery](docs/05-delivery/README.md) | CI, BuildKit, scanning, immutable artifacts, CD |
| [06 — Governance and resilience](docs/06-governance-resilience/README.md) | admission policy, fixed-capacity scheduling, canary releases |
| [07 — Operations and validation](docs/07-operations-validation/README.md) | bootstrap, secrets, recovery, validation, clean rebuild |

[`docs/README.md`](docs/README.md) explains the documentation structure and implementation ownership.