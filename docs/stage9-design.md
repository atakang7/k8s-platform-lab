# Stage 9 — Resource and Release Design

Stage 9 answers the two design questions from the requirements. It does not introduce another production platform. The existing `sample-java-app` is treated as App X; App Y is modeled as interruptible batch work.

## 1. Fixed-capacity cluster: protect App X, let App Y yield

### Model

App X is our existing `sample-java-app`: real-time, highly available, and performance-sensitive. App Y is batch work that can be paused, killed, and retried. The cluster cannot add nodes.

The first requirement is not burst scaling. It is preserving App X's minimum operating footprint.

```text
baseline

sample-java-app
4 healthy replicas minimum
resource requests already defined
spread across node-2 / node-3
          ↓
this is the capacity App X must retain

remaining cluster capacity
          ↓
low-priority batch Jobs / CronJobs
```

Under load:

```text
App X HPA wants > 4 replicas
             ↓
free capacity exists? ── yes ──→ schedule normally
             │
             no
             ↓
high-priority App X Pod remains pending
             ↓
Kubernetes preempts lower-priority App Y Pod(s)
             ↓
App X gets capacity
             ↓
App Y retries / resumes later
```

### Choice

Use Kubernetes-native scheduling controls around the existing application:

- **Minimum App X footprint** — HPA `minReplicas: 4`; the four running replicas and their existing resource requests are the baseline that must remain available.
- **HPA for App X** — scales above the floor when demand increases.
- **PriorityClass** — App X receives much higher scheduling priority than App Y.
- **Preemption** — if the cluster is full, pending App X Pods may displace lower-priority App Y Pods.
- **Topology spread** — keep App X replicas distributed across both workers.
- **PDB** — protect App X availability during voluntary disruptions.
- **Job/CronJob semantics for App Y** — batch work should be restartable/idempotent or checkpointed, because interruption is expected by design.

Sample: [`stage9-resource-pressure.yaml`](./stage9-resource-pressure.yaml)

The existing App X Deployment remains the source of truth. To participate in this policy it only needs `priorityClassName: app-x-critical` in its Pod template; the Stage 9 sample does not duplicate the production Deployment.

### Capacity nuance

`PriorityClass` does **not** reserve future burst capacity. Kubernetes cannot manufacture CPU or memory on a fixed cluster.

The protected baseline comes from having the minimum App X replicas already scheduled with resource requests. HPA may then request additional replicas. If there is no spare capacity, priority/preemption decides which workload gives way.

So the intended model is:

```text
App X baseline capacity
        +
App Y uses spare capacity
        +
App X may reclaim App Y capacity when it bursts
```

HPA itself also requires a Kubernetes metrics API (for example metrics-server, or an adapter for custom/external metrics). The sample shows the scheduling design rather than claiming that the current lab already provides that API.

### Why App Y is a CronJob-style workload

The requirements describe App Y as batch work that can be killed or paused. A `Job` / `CronJob` is therefore a more natural model than another long-running Deployment.

Preemption intentionally reduces App Y throughput during pressure. That is acceptable only because App Y is designed to tolerate interruption and resume later.

---

## 2. Critical application release: canary traffic shifting

### Choice

Use a **canary deployment** for the existing application rather than replacing the entire production fleet at once.

The current `sample-java-app` Deployment, Service, and Ingress remain the stable path. A second candidate Deployment and Service receive only a small fraction of traffic through ingress-nginx.

```text
initial

users ───────────────→ stable v1 100%

candidate introduced

users ──┬────────────→ stable v1 95%
        └────────────→ canary v2  5%

observe errors / latency / readiness / restarts
        ↓
5% → 10% → 25% → 50% → 100%
        ↓
promote v2
```

Sample: [`stage9-canary.yaml`](./stage9-canary.yaml)

### Release procedure

1. Leave the current `sample-java-app` Deployment, Service, and primary Ingress untouched.
2. Deploy the candidate version as a separate canary Deployment and Service using the same production pod conventions.
3. Add an ingress-nginx canary Ingress for `app.lab.test` with a small weight, initially 5%.
4. Observe readiness, application errors, latency, restart rate, and other application-specific signals.
5. Increase weight gradually: 5% → 10% → 25% → 50% → 100%.
6. If signals regress, set the canary weight to 0 or remove the canary Ingress. Stable v1 never stopped serving.
7. When v2 is proven, update the normal deployment pipeline to promote that image to the stable Deployment, then remove the temporary canary resources.

### Why canary

Our existing RollingUpdate configuration protects availability during a normal deployment, but a healthy Pod can still contain an application-level regression. Canary limits the blast radius by exposing the candidate to only a controlled fraction of real traffic first.

Blue/green would also give fast rollback, but without traffic weighting its cutover is much larger. Canary directly addresses the requirement to describe a gradual traffic shift.

### Tradeoff

For a short period two versions run at once, so canary consumes additional cluster capacity. On this fixed-capacity cluster, the candidate should start small and promotion should only increase its footprint as capacity permits.
