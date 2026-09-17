# Production documentation

The root [`README.md`](../README.md) is the entry point. This directory explains how the platform is built, operated, validated, and changed.

The documentation is ordered by dependency. Each stage owns one operational layer and points to the Git paths that implement it.

| Stage | Layer | Document |
|---:|---|---|
| 1 | VM and Kubernetes foundation | [`stage-01-foundation.md`](stage-01-foundation.md) |
| 2 | Edge, DNS, TLS, and secrets | [`stage-02-edge-trust.md`](stage-02-edge-trust.md) |
| 3 | Shared platform services | [`stage-03-platform-services.md`](stage-03-platform-services.md) |
| 4 | Application runtime | [`stage-04-application-runtime.md`](stage-04-application-runtime.md) |
| 5 | CI/CD and artifact flow | [`stage-05-delivery.md`](stage-05-delivery.md) |
| 6 | Admission policy | [`stage-06-admission-policy.md`](stage-06-admission-policy.md) |
| 7 | Capacity and release strategy | [`stage-07-capacity-release.md`](stage-07-capacity-release.md) |
| 8 | Validation and clean rebuild | [`stage-08-validation-rebuild.md`](stage-08-validation-rebuild.md) |

## Build dependency

```text
┌──────────────────────┐
│ 1. Foundation        │  VMs · containerd · kubeadm · Calico · storage
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ 2. Edge + trust      │  Vault · BIND9 · CA · MetalLB · ingress · VSO
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ 3. Platform services │  Jenkins · Prometheus · Grafana · logs
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ 4. Application       │  image · probes · 4 replicas · sidecar logging
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ 5. Delivery          │  CI → digest → CD → rollout verification
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ 6. Admission policy  │  Deployment CPU + memory request enforcement
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ 7. Capacity/release  │  priority · preemption · HPA · canary
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ 8. Validation        │  outcome checks · clean-room rebuild proof
└──────────────────────┘
```

Stages 1-6 are implemented platform state. Stage 7 documents production scheduling and release behavior. Stage 8 defines how the repository is proven reproducible.

## Documentation roles

[`architecture.md`](architecture.md) is the system map. [`design.md`](design.md) records the important engineering choices and tradeoffs. [`operations.md`](operations.md) contains operator procedures, secrets bootstrap, recovery, and day-two commands.

Folder-level README files explain local ownership and commands:

- [`../infra/README.md`](../infra/README.md)
- [`../platform/README.md`](../platform/README.md)
- [`../app/README.md`](../app/README.md)
- [`../delivery/README.md`](../delivery/README.md)
- [`../policies/README.md`](../policies/README.md)
- [`../validation/README.md`](../validation/README.md)

## Operating principle

The repository is desired state. A working cluster is evidence, not the source of truth. Permanent changes are made in Git, reconciled through the documented entry points, and then validated from observable outcomes.