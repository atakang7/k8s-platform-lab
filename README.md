# Lab Kubernetes Platform

This repository is the source of truth for the infrastructure, Kubernetes platform, application runtime, delivery path, policy controls, and operating procedures. The environment is built from Git-managed configuration; credentials stay outside Git and are delivered from Vault to the consumers that need them.

```text
                         HOST / TRUST BOUNDARY

┌──────────┐   signs   ┌────────────────────┐   stored in   ┌─────────┐
│ local CA │──────────►│ wildcard TLS cert  │──────────────►│  Vault  │
└──────────┘           └────────────────────┘               └────┬────┘
                                                                 │ Vault API
                                                                 ▼
                                                        ┌──────────────────┐
                                                        │ Vault Secrets    │
                                                        │ Operator         │
                                                        └────────┬─────────┘
                                                                 │
                                                                 ▼
                                                        Kubernetes Secrets

┌────────────────────┐   signed RFC2136 / TSIG   ┌──────────────────┐
│ BIND9              │◄──────────────────────────│ ExternalDNS      │
│ lab.test    │                           │ watches K8s      │
└────────────────────┘                           └──────────────────┘

                         KUBERNETES / DATA PATH

┌─────────┐   assigns + L2 advertises   ┌────────────────────────────┐
│ MetalLB │────────────────────────────►│ ingress Service · .200     │
└─────────┘                             └──────────────┬─────────────┘
                                                     │
                                                     ▼
                                            ingress-nginx ×2
                                                     │ HTTPS routing
                          ┌──────────────────────────┼─────────────────────┐
                          │                          │                     │
                          ▼                          ▼                     ▼
                  sample-java-app               Jenkins            observability
                  4 replicas                    controller         metrics + logs
                  node-2 / node-3               node-3 · 0 execs
                                                     │
                                                     ▼
                                                CI/CD agents
                                                node-3

node-1                      node-2                      node-3
control plane               worker                      worker
10.50.0.10                  10.50.0.11                 10.50.0.12
                            192.168.56.11               192.168.56.12
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