# 06 — Governance and resilience

This layer defines what workloads are allowed to enter the cluster and how critical workloads behave when capacity or release risk becomes the constraint.

```text
DESIRED-STATE CONTROL

kubectl / controller
        │
        ▼
Kubernetes API server
        │
        ▼
validating admission webhook
        │
        ├── invalid ──► reject write
        │
        └── valid ────► continue admission / persist
```

```text
RUNTIME CONTROL

metrics ──► HPA ──► desired replicas
                     │
                     ▼
                  scheduler
                     │
         priority / preemption / spread
                     │
                     ▼
               running Pods
                     │
                     ▼
             ingress traffic
                     │
             stable / canary split
```

These are different controls. Admission rejects invalid desired state before it is stored. Scheduling, autoscaling, disruption protection, and traffic shifting operate on valid runtime state after admission.

## Pages

| Concern | Documentation |
|---|---|
| Deployment resource-request enforcement | [`admission-policy.md`](admission-policy.md) |
| fixed-capacity scheduling and canary release | [`capacity-release.md`](capacity-release.md) |

The reference manifests in this folder are design examples for capacity and canary behavior. They are not part of the normal baseline reconciliation path.
