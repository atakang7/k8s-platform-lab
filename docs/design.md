# Design decisions

This document records the decisions that materially affect availability, security, delivery, or reproducibility. It is not a component inventory; implementation details live in the staged documents.

## Platform invariants

| Invariant | Enforcement |
|---|---|
| control plane is not host-exposed | `node-1` has no edge NIC |
| public entry uses one controlled VIP | MetalLB pool with explicit allocation; ingress owns `192.168.56.200` |
| secrets are not committed | Vault is credential authority; VSO/Vault Agent materialize runtime copies |
| Jenkins controller does not build | `numExecutors: 0`; exclusive Kubernetes agents |
| application does not run on control plane | required node affinity |
| application baseline is distributed | 4 replicas + topology spread `maxSkew: 1` |
| normal rollout does not intentionally drop capacity | `maxUnavailable: 0` + readiness |
| release artifact is immutable | CD accepts only `repository@sha256:...` |
| release source is immutable | CD accepts full Git SHA and checks it out detached |
| Deployment containers declare CPU + memory requests | validating admission webhook |
| permanent state comes from Git | manual cluster edits are not desired state |

## Cluster topology

A single control plane and two workers match the required local footprint and keep the environment small enough to rebuild frequently.

`kubeadm` is used instead of a local-development Kubernetes distribution because the cluster should behave like a standard Kubernetes installation. containerd is the runtime. Calico owns Pod networking. local-path provides dynamic PVCs without introducing an external storage system.

Tradeoff: the API server and local-path volumes are not highly available. This environment demonstrates production control patterns, not multi-control-plane or distributed-storage HA.

## Network isolation

The private node network is `10.50.0.0/24`. Only worker nodes join `192.168.56.0/24` for host-facing ingress.

```text
host traffic
    │
    ▼
worker edge NICs
    │
    ▼
ingress

node-1 control plane
    │
    └── private network only
```

This keeps host-facing traffic away from the control-plane interface while still allowing MetalLB Layer 2 advertisement from workers.

## Edge VIP ownership

MetalLB's edge pool has automatic allocation disabled. The ingress controller explicitly requests `192.168.56.200`.

Reason: a newly created `LoadBalancer` Service must not accidentally consume an address from the host-visible range.

Tradeoff: exposure is deliberate but requires explicit annotations/values when new edge services are introduced.

## DNS

BIND9 is authoritative for `lab.test`. ExternalDNS watches Kubernetes resources and writes records through RFC2136 using TSIG authentication.

```text
Kubernetes desired state
        │
        ▼
ExternalDNS
        │ authenticated RFC2136
        ▼
BIND9
        │
        ▼
managed DNS records
```

This avoids manually synchronizing hostnames with Ingress objects.

Tradeoff: the reference environment has one authoritative DNS server. DNS service itself is not redundant.

## Secret authority

Vault runs outside workload lifecycle on the host. Secret consumers authenticate through narrowly scoped AppRoles.

VSO delivers Kubernetes-native Secrets to cluster workloads. Vault Agent delivers the BIND TSIG key to a protected host runtime path.

Reason: consumers use their normal secret interfaces while the value authority remains outside Git and outside application configuration.

Tradeoff: VSO creates runtime secret copies in Kubernetes etcd. Namespace RBAC still matters. Vault itself is single-host in this environment.

## Local PKI

A local CA provides trusted TLS for Vault and `*.lab.test`. The host trusts the CA through the normal system trust store.

The CA private key is operator-held host state and is not committed.

Tradeoff: trust is intentionally local to this environment. A production network would use organizational/public PKI with managed issuance and rotation.

## Jenkins execution model

The Jenkins controller is pinned to `node-3`, persists `JENKINS_HOME`, and has zero executors.

CI and CD run on separate exclusive agent templates:

```text
controller
   │
   ├──► CI runner  ── build / test / scan / publish
   │
   └──► CD runner  ── deploy / verify
```

Reason: controller orchestration and workload execution have different failure and security boundaries.

One CI runner and one CD runner are sufficient for this environment. CI scaling later would require isolated BuildKit state per concurrent worker to avoid cache/state collisions.

## Warm CI caches

Maven, Trivy, and BuildKit caches are stored on `node-3` host paths. Agent Pods can be recreated without losing warm cache state.

Reason: the environment is fixed-node and CI latency matters more than portable cache storage.

Tradeoff: cache state is tied to `node-3`; it is an optimization, not a source of truth. Cold rebuilds must still succeed.

## CI validation order

Configuration and application validation occurs before registry publication. Independent checks run in parallel.

```text
tests + lint + server dry-run + Ansible syntax
                     │
                     ▼
                 BuildKit
                     │
                     ▼
               Trivy + SBOM
                     │
                     ▼
               registry push
```

The server-side Kubernetes dry-run intentionally uses the live API server so schema and admission policy are checked without leaving test workloads.

## Vulnerability reporting

Trivy scans HIGH and CRITICAL findings and generates a CycloneDX SBOM before publication.

Current policy is report-only by default because `TRIVY_EXIT_CODE=0` unless overridden.

Reason: scanning and provenance are always produced while allowing the enforcement threshold to remain an explicit organizational policy.

Do not describe the current configuration as a blocking vulnerability gate.

## Immutable artifact handoff

CI passes CD a full Git SHA and an immutable registry digest. CD rejects mutable image references.

```text
commit SHA ──────────┐
                     ├── release identity
image digest ────────┘
```

CD checks out the exact commit before applying that commit's deployment automation, then verifies the live Deployment reports the requested digest.

This prevents branch movement or mutable tags from changing what a release means after CI completes.

## Application availability

The stable application runs four replicas, excludes the control plane, and spreads across worker hostnames.

`RollingUpdate` uses `maxUnavailable: 0` and `maxSurge: 4`. Readiness controls when replacement Pods can receive traffic.

Reason: the fixed cluster has enough reference capacity to create replacement replicas before intentionally removing old ones.

Tradeoff: surge temporarily consumes more capacity. If the cluster is heavily constrained, rollout capacity must be planned with workload priority and batch eviction policy.

## Application logging

The Java process writes an asynchronous local file with daily/size rotation and a total retained size cap. A Fluent Bit sidecar reads the shared file and ships it to Elasticsearch.

Reason: application request handling is decoupled from network log delivery while still meeting explicit file-logging requirements.

The node-level Fluent Bit remains responsible for general Kubernetes container logs. The sidecar exists specifically for the application file log.

## Observability storage

Prometheus, Elasticsearch, and Jenkins use local-path PVCs.

Reason: the environment has no external distributed storage and should stay reproducible on a developer host.

Tradeoff: Pod recreation is supported; worker loss is not storage-HA.

## Admission enforcement

The resource-request rule is enforced through a custom validating webhook because the required invariant is evaluated on Deployment container specifications before persistence.

`failurePolicy: Fail` makes in-scope Deployment changes fail closed if the policy service is unavailable.

System namespaces and the webhook's own namespace are excluded to avoid bootstrapping deadlocks.

## Fixed-capacity scheduling

The critical application keeps a four-replica baseline with resource requests. HPA can request burst replicas up to the documented maximum. The application has higher scheduling priority than restartable batch work.

```text
baseline app capacity already scheduled
        │
load rises
        ▼
HPA requests more replicas
        │
cluster full
        ▼
priority / preemption
        │
low-priority batch yields
        ▼
critical app schedules
```

PriorityClass does not reserve future capacity. It decides contention. The baseline guarantee comes from already scheduled minimum replicas and their requests.

## Critical release strategy

Critical versions use canary traffic shifting on top of the normal RollingUpdate behavior.

A candidate Deployment and Service are exposed by an ingress-nginx canary Ingress for the same host/path. Traffic starts small and is increased only after health, latency, error, and restart signals remain acceptable.

Rollback is traffic-first: set canary weight to zero or remove the canary Ingress while the stable version continues serving.

Tradeoff: canary temporarily needs extra compute capacity and must not consume the stable baseline.

## Reproducibility rule

A healthy existing cluster is not the acceptance criterion. The repository is reproducible only when a fresh checkout plus documented operator-held secrets can recreate the platform without undocumented manual repairs.

If a clean rebuild requires manual cluster surgery, the missing action belongs in Git or in an explicit operator procedure.