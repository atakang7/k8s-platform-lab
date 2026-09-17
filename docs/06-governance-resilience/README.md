# 06 — Governance and resilience

This layer defines what workloads are allowed to enter the cluster and how critical workloads behave when capacity or release risk becomes the constraint.

```text
                        Kubernetes API
                             │
                ┌────────────┴────────────┐
                │                         │
                ▼                         ▼
      admission governance       runtime resilience
                │                         │
                ▼                         ▼
 CPU + memory requests      baseline capacity + HPA
 must exist on Deployments  priority + preemption
                            PDB + topology spread
                            canary traffic shifting
```

These are different controls. Admission rejects invalid desired state before it is stored. Scheduling and release controls decide how valid workloads share capacity and how new versions receive traffic.

## Pages

| Concern | Documentation |
|---|---|
| Deployment resource-request enforcement | [`admission-policy.md`](admission-policy.md) |
| fixed-capacity scheduling and canary release | [`capacity-release.md`](capacity-release.md) |

The reference manifests in this folder are design examples for capacity and canary behavior. They are not part of the normal baseline reconciliation path.
