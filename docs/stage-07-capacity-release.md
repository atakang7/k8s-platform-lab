# Stage 7 — Capacity and release strategy

This stage documents two production behaviors that sit above the base runtime: how the application behaves when the cluster is full, and how a critical version is introduced without sending all traffic to it at once.

## Capacity model

The existing `sample-java-app` is the critical real-time workload. Its minimum operating footprint is kept running before burst demand appears.

```text
                           FIXED CLUSTER CAPACITY

      ┌─────────────────────────────────────────────────────┐
     /                                                     /│
    /  baseline capacity                                  / │
   └─────────────────────────────────────────────────────┘  │
   │                                                        │
   │  sample-java-app                                       │
   │  4 replicas minimum                                    │
   │  CPU + memory requests                                 │
   │  spread across node-2 / node-3                        │
   │                                                        │
   └────────────────────────────────────────────────────────┘

                         spare capacity
                              │
                              ▼
                 ┌────────────────────────┐
                 │ low-priority batch    │
                 │ Job / CronJob Pods    │
                 └────────────────────────┘
```

The baseline is not created by PriorityClass. It exists because the minimum application replicas are already scheduled with resource requests.

Priority and preemption control what happens when the application needs capacity beyond that baseline.

## Pressure flow

```text
application load rises
        │
        ▼
┌──────────────────────┐
│ HPA                  │
│ min 4 · max 8        │
└──────────┬───────────┘
           │ asks for additional replicas
           ▼
cluster has free capacity?
      │             │
     yes            no
      │             │
      ▼             ▼
schedule       App X Pods Pending
replicas             │
                     ▼
             PriorityClass comparison
                     │
                     ▼
       low-priority batch Pods selected
              for preemption
                     │
                     ▼
           capacity becomes free
                     │
                     ▼
        critical replicas schedule
                     │
                     ▼
        batch work retries later
```

The critical application uses a high PriorityClass. Batch work uses a low PriorityClass and is designed to be restartable/idempotent or checkpointed.

HPA alone cannot solve a full-cluster problem. It can request replicas, but without capacity those replicas remain Pending. Priority and preemption provide the mechanism for reclaiming expendable batch capacity.

## Availability controls

The critical application uses three separate mechanisms with different jobs:

| Mechanism | Purpose |
|---|---|
| resource requests | scheduler footprint for each running Pod |
| HPA | requests more/fewer replicas from load signals |
| PriorityClass + preemption | decides who yields when capacity is exhausted |
| topology spread | keeps critical replicas distributed across workers |
| PDB | limits voluntary disruption of the critical workload |

A PDB does not reserve CPU or memory. It protects availability during voluntary disruption such as maintenance or eviction APIs.

Reference manifest: [`stage9-resource-pressure.yaml`](stage9-resource-pressure.yaml).

## Critical release model

The stable application remains live while a candidate version is introduced beside it.

```text
                         app.lab.test
                                │
                                ▼
                    ┌──────────────────────┐
                    │ ingress-nginx        │
                    │ same host + path     │
                    └──────────┬───────────┘
                               │
                    ┌──────────┴──────────┐
                    │ weighted routing    │
                    │                    │
                  95%                    5%
                    │                    │
                    ▼                    ▼
       ┌────────────────────┐   ┌────────────────────┐
       │ stable Service     │   │ canary Service     │
       │ current version    │   │ candidate version │
       └─────────┬──────────┘   └─────────┬──────────┘
                 │                        │
                 ▼                        ▼
           stable Pods              canary Pod(s)
```

The canary is a separate Deployment and Service. A second ingress for the same host/path uses ingress-nginx canary annotations and starts with a small weight.

Reference manifest: [`stage9-canary.yaml`](stage9-canary.yaml).

## Promotion strategy

```text
candidate deployed
      │
      ▼
5% traffic
      │
      ▼
health + readiness + errors + latency + restarts acceptable?
      │
      ├── no ──► weight 0 / remove canary ingress ──► stable stays live
      │
      ▼ yes
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
promote candidate into stable release path
 │
 ▼
remove temporary canary resources
```

Traffic percentage is increased only after the candidate remains healthy at the current step. The exact hold time is an operational policy; the mechanism is independent of that duration.

## Why canary instead of only RollingUpdate

The normal stable Deployment already uses a safe RollingUpdate. That protects replica availability during replacement, but it still moves the production fleet directly toward the new version.

Canary adds a separate risk boundary: most users remain on the known-good version while a small share exercises the candidate with real traffic.

Blue/green would also keep two versions, but the requirements require controlled traffic shifting. ingress-nginx canary weighting directly provides that behavior with the existing edge stack.

## Capacity tradeoff during canary

Canary temporarily consumes capacity in addition to the stable workload. In this fixed cluster, candidate replica count and traffic steps must therefore be conservative. A release must not consume the capacity required to maintain the stable application's baseline.

## Source paths

`docs/stage9-resource-pressure.yaml` is the scheduling/capacity reference. `docs/stage9-canary.yaml` is the canary reference. These are design manifests, not part of normal cluster reconciliation.