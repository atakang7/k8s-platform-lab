# Capacity and release resilience

The cluster has fixed nodes. The design therefore separates guaranteed baseline capacity from burst capacity and treats batch work as expendable before the critical application.

## Capacity model

The existing `sample-java-app` is the critical real-time workload.

```text
                         FIXED WORKER CAPACITY

┌────────────────────────────────────────────────────────────────────┐
│ critical baseline                                                  │
│                                                                    │
│ sample-java-app                                                    │
│ 4 running replicas · explicit CPU/memory requests                  │
│ spread across node-2 / node-3                                      │
├────────────────────────────────────────────────────────────────────┤
│ remaining capacity                                                 │
│                                                                    │
│ low-priority batch Job / CronJob Pods                              │
│ restartable / idempotent                                           │
└────────────────────────────────────────────────────────────────────┘
```

The minimum capacity is not created by PriorityClass. It exists because four application replicas are already scheduled with explicit requests.

Priority and preemption only decide who yields when the application wants to grow beyond that baseline.

## Pressure flow

```text
load rises
   │
   ▼
HPA · min 4 / max 8 · target CPU 65%
   │
   ▼
requests additional application replicas
   │
   ▼
free worker capacity?
   │
   ├── yes ──► scheduler places new replicas
   │
   └── no
       │
       ▼
new high-priority app Pod remains Pending
       │
       ▼
scheduler evaluates lower-priority victims
       │
       ▼
interruptible batch Pod is preempted
       │
       ▼
resources become available
       │
       ▼
critical app Pod schedules
       │
       ▼
batch work retries / resumes later
```

The reference HPA scales up by up to two Pods or 100% per minute and uses a 300-second scale-down stabilization window. Fast scale-up protects the service during demand spikes; delayed scale-down avoids immediately collapsing capacity after a short dip.

## Control separation

| Mechanism | Responsibility |
|---|---|
| resource requests | scheduler footprint of each running Pod |
| `minReplicas: 4` | minimum application replica floor |
| HPA | asks for burst replicas based on load |
| PriorityClass | marks the application more important than batch work |
| preemption | reclaims capacity from lower-priority Pods when required |
| topology spread | keeps critical replicas distributed across workers |
| PDB | protects minimum availability during voluntary disruption |

A PDB does not reserve CPU or memory. HPA does not create node capacity. PriorityClass does not guarantee idle headroom. Each control solves one part of the problem.

The batch workload is modeled as a `CronJob`, not another long-running Deployment, because the workload is explicitly pausable/restartable. Its work should be idempotent or checkpointed so eviction is operationally acceptable.

Reference manifest: [`capacity-pressure.yaml`](capacity-pressure.yaml).

## Critical release model

The normal Deployment already uses `RollingUpdate` with `maxUnavailable: 0`. That protects replica availability, but it still moves the stable fleet directly toward a new version.

For a high-risk release, the stable version stays in place and a candidate is introduced as a separate Deployment and Service.

```text
                         app.lab.test
                                  │
                                  ▼
                         ingress-nginx
                                  │
                    same host + same path
                                  │
                 ┌────────────────┴────────────────┐
                 │                                 │
                 ▼                                 ▼
        stable Ingress                    canary Ingress
        normal route                      canary=true
                                          weight=5
                 │                                 │
               ~95%                               ~5%
                 │                                 │
                 ▼                                 ▼
        stable Service                     canary Service
                 │                                 │
                 ▼                                 ▼
          stable Pods                       candidate Pod(s)
```

The traffic split is configured by ingress-nginx canary annotations on the second Ingress for the same host/path.

## Promotion flow

```text
candidate deployed
      │
      ▼
5% traffic
      │
      ▼
health · readiness · errors · latency · restarts acceptable?
      │
      ├── no ──► set weight 0 / remove canary Ingress
      │                         │
      │                         ▼
      │                  stable keeps serving
      │
      └── yes
           │
           ▼
          10%
           │
           ▼
          25%
           │
           ▼
          50%
           │
           ▼
         100%
           │
           ▼
promote candidate through normal stable release path
           │
           ▼
remove temporary canary Deployment / Service / Ingress
```

The exact hold time at each step is an operating policy. Traffic only increases after the candidate remains healthy at the current weight.

## Rollback

Canary rollback does not require replacing the stable Deployment.

```text
candidate unhealthy
      │
      ▼
set canary weight to 0
or remove canary Ingress
      │
      ▼
ingress-nginx routes requests to stable Ingress only
      │
      ▼
stable Service / Pods continue serving
```

This is the main risk reduction: the known-good release remains present while the candidate is evaluated.

## Capacity during canary

A canary temporarily consumes capacity in addition to the stable four-replica baseline. Candidate replica count must therefore stay conservative on this fixed cluster. Release testing is not allowed to consume the capacity required to keep the stable service healthy.

Reference manifest: [`canary-release.yaml`](canary-release.yaml).
