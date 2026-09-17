# Documentation map

The documentation is organized by operational layer, not by repository history. Read top to bottom for the full build path; open one layer in isolation when changing or debugging that subsystem.

```text
┌──────────────────────────────────────────────┐
│ 01 · Foundation                              │
│ VMs · kubeadm · containerd · Calico · PVCs │
└──────────────────────┬───────────────────────┘
                       ▼
┌──────────────────────────────────────────────┐
│ 02 · Edge + trust                            │
│ Vault · DNS · TLS · MetalLB · ingress · VSO │
└──────────────────────┬───────────────────────┘
                       ▼
┌──────────────────────────────────────────────┐
│ 03 · Platform services                       │
│ Jenkins · metrics · alerts · logs            │
└──────────────────────┬───────────────────────┘
                       ▼
┌──────────────────────────────────────────────┐
│ 04 · Application runtime                     │
│ image · probes · placement · rollout · logs  │
└──────────────────────┬───────────────────────┘
                       ▼
┌──────────────────────────────────────────────┐
│ 05 · Delivery                                │
│ test · build · scan · digest · deploy        │
└──────────────────────┬───────────────────────┘
                       ▼
┌──────────────────────────────────────────────┐
│ 06 · Governance + resilience                 │
│ admission · capacity · preemption · canary   │
└──────────────────────┬───────────────────────┘
                       ▼
┌──────────────────────────────────────────────┐
│ 07 · Operations + validation                 │
│ bootstrap · recovery · checks · clean rebuild│
└──────────────────────────────────────────────┘
```

## Layers

| Layer | Owns | Page |
|---|---|---|
| 01 | VMs, kubeadm, containerd, Calico, storage, cluster CIDRs | [`01-foundation/`](01-foundation/README.md) |
| 02 | Vault, BIND9, CA, MetalLB, ingress, ExternalDNS, VSO | [`02-edge-trust/`](02-edge-trust/README.md) |
| 03 | Jenkins, Prometheus, AlertManager, Grafana, Fluent Bit, Elasticsearch | [`03-platform-services/`](03-platform-services/README.md) |
| 04 | Java image, Kubernetes workload, probes, resources, logging | [`04-application-runtime/`](04-application-runtime/README.md) |
| 05 | CI checks, BuildKit, Trivy/SBOM, immutable digest, Ansible CD | [`05-delivery/`](05-delivery/README.md) |
| 06 | validating webhook, resource policy, priority/preemption, HPA, canary | [`06-governance-resilience/`](06-governance-resilience/README.md) |
| 07 | bootstrap, secret entry, recovery, validation, clean rebuild | [`07-operations-validation/`](07-operations-validation/README.md) |

## Page contract

Each layer follows the same order:

```text
scope
  │
  ▼
architecture / data flow
  │
  ▼
implementation
  │
  ▼
engineering choices / optimizations
  │
  ▼
operator interface
  │
  ▼
validation / failure boundary
  │
  ▼
source paths
```

This keeps implementation facts beside the reason they exist. A cache, topology constraint, rollout setting, secret boundary, or scheduling rule is documented where that technology is introduced instead of being repeated later in a separate "design decisions" document.

## Ownership

The documentation explains the system. The implementation remains in the owning repository folders:

| Path | Owns |
|---|---|
| [`../infra/`](../infra/) | machine, cluster, host edge |
| [`../platform/`](../platform/) | Kubernetes-resident shared services |
| [`../app/`](../app/) | application source, image, runtime manifests |
| [`../delivery/`](../delivery/) | build, scan, publish, deployment automation |
| [`../policies/`](../policies/) | admission control implementation |
| [`../validation/`](../validation/) | observable system checks |

The repository is desired state. A working cluster is evidence, not the source of truth.