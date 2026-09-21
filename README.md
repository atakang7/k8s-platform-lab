# Lab Kubernetes Platform

A local Kubernetes platform built as a production-style system: infrastructure, ingress, secrets, CI/CD, observability, policy enforcement, and an application release flow are all managed from this repository.

```text
                         GitHub
                           │
                           ▼
                        Jenkins
                           │
                    build · verify
                           │
                           ▼
                    state/<env>.yaml
                           │
                           ▼
                        Kubernetes
                           │
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
       ingress         application      observability
          ▲
          │
       MetalLB
          ▲
          │
client ─► BIND9

Vault ─► Vault Secrets Operator ─► Kubernetes Secrets
```

The lab runs on three VMs:

```text
node-1                 node-2                 node-3
control plane          worker                 worker
                                               │
                                               ├─ Jenkins
                                               └─ CI/CD agents
```

## Start here

**Building or operating the environment?**  
→ [RUNBOOK.md](RUNBOOK.md)

**Understanding the release flow?**  
→ [DELIVERY.md](DELIVERY.md)

## Repository map

| Area | What it owns |
|---|---|
| [`infra/`](infra/README.md) | VMs, Kubernetes foundation, host DNS, Vault and trust |
| [`platform/`](platform/README.md) | Kubernetes edge, Jenkins, environment setup and observability |
| [`delivery/`](delivery/README.md) | Jenkins pipelines and delivery implementation |
| [`state/`](state/) | desired release for each environment |
| [`app/`](app/README.md) | sample application and its runtime configuration |
| [`charts/service/`](charts/service/README.md) | shared service chart |
| [`policies/`](policies/README.md) | admission controls |
| [`validation/`](validation/README.md) | cluster, platform and end-to-end validation |

## Key component docs

- [Jenkins](platform/jenkins/README.md) — jobs, agents, credentials and configuration
- [Edge](infra/edge/README.md) — DNS, TLS, Vault and ingress bootstrap
- [Observability](platform/observability/README.md) — metrics, dashboards and logs
- [Resource request policy](policies/resource-requests-webhook/README.md) — admission webhook behavior
- [CI agent image](delivery/jenkins/README.md) — Jenkins agent image lifecycle

## Requirements

The complete environment is intended to run from an **Ubuntu x86_64** operator host with VirtualBox, Vagrant, Ansible, Kubernetes/Helm tooling, GNU Make and the standard CLI utilities used by the repository.

Exact bootstrap order and credential setup are kept in the [runbook](RUNBOOK.md).
