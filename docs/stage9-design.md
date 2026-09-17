# Stage 9 — Resource and Release Design

Stage 9 answers the two design questions from the requirements. These manifests are illustrative architecture samples; they are not part of the live application deployment.

## 1. Fixed-capacity cluster: App X vs App Y

### Goal

App X is real-time, highly available, and performance-sensitive. App Y runs interruptible batch work. The cluster cannot add nodes, so scaling App X must reclaim capacity from App Y when necessary.

```text
normal load

node-2                     node-3
┌───────────────┐          ┌───────────────┐
│ App X         │          │ App X         │
│ App Y         │          │ App Y         │
└───────────────┘          └───────────────┘

heavy load

App X HPA requests more replicas
             ↓
cluster has no free capacity
             ↓
PriorityClass + preemption
             ↓
lower-priority App Y pods yield capacity
             ↓
App X replicas schedule across both workers
```

### Choice

Use four mechanisms together:

- **HPA for App X** — increases/decreases replicas from load signals.
- **PriorityClass** — App X receives much higher scheduling priority than App Y.
- **Preemption** — when the cluster is full, pending App X pods may displace lower-priority App Y pods.
- **Topology spread + PDB** — keep App X distributed across workers and protect availability during voluntary disruptions.

The request/limit values in the sample are illustrative because the requirements state those values are already defined. The important part is the scheduling policy around them.

Sample: [`stage9-resource-pressure.yaml`](./stage9-resource-pressure.yaml)

### Why this fits a fixed cluster

HPA alone cannot create physical capacity. On a full cluster it can create additional App X Pods, but they remain Pending. Priority and preemption give Kubernetes a controlled way to free capacity by evicting the workload that the scenario explicitly says is safe to interrupt.

A PDB protects App X from voluntary disruptions such as maintenance; it is not a resource-reservation mechanism and is not a substitute for priority/preemption.

### Tradeoff

Preemption deliberately sacrifices App Y throughput during pressure. That is acceptable here because App Y is pausable/killable. In a production batch system, the batch work must be restartable/idempotent or checkpointed.

HPA also requires a metrics API. In production that can be supplied by metrics-server or an adapter for custom/external metrics.

---

## 2. Critical application release: canary traffic shifting

### Choice

Use a **canary deployment** rather than replacing the entire production version at once.

```text
initial

users ───────────────→ v1 100%

canary

users ──┬────────────→ v1 95%
        └────────────→ v2  5%

observe errors / latency / health
        ↓
5% → 10% → 25% → 50% → 100%
        ↓
promote v2
```

With ingress-nginx, a second Ingress for the same host/path can be marked as a canary and assigned a traffic weight.

Sample: [`stage9-canary.yaml`](./stage9-canary.yaml)

### Release procedure

1. Keep v1 Deployment, Service, and primary Ingress unchanged.
2. Deploy v2 as a separate Deployment and Service.
3. Create the canary Ingress with a small weight (for example 5%).
4. Observe readiness, error rate, latency, restart rate, and application-specific signals.
5. Increase weight gradually: 5% → 10% → 25% → 50% → 100%.
6. If signals regress, set canary weight to 0/remove the canary Ingress; v1 remains available.
7. After v2 is proven, update the stable Deployment to v2 and remove the temporary canary resources.

### Why canary

A RollingUpdate limits unavailable replicas, but it still replaces the production fleet directly. Canary keeps the known-good version serving most traffic while the new version is exposed to a controlled fraction of real requests.

Blue/green also provides fast rollback, but the cutover is normally much larger unless an additional traffic-splitting layer is added. For this question, canary directly demonstrates the requested gradual traffic shift.

### Tradeoff

For a short period two versions are running simultaneously, which consumes extra cluster capacity. In a fixed-capacity environment, the canary replica count and rollout weights must therefore be chosen conservatively.
