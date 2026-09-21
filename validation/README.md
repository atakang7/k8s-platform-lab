# Validation

`validation/` proves observable outcomes. It does not own platform
configuration and it does not repair broken state.

## 1. Validation model

~~~text
desired state
infra / platform / app
delivery / policies
        │
        │ reconcile
        ▼
running system
        │
        ▼
validation
        │
   ┌────┴─────┐
   │          │
 PASS        FAIL
              │
              ▼
      fix owning subsystem
              │
              ▼
          rerun check
~~~

Validation is evidence, not configuration management.

## 2. Validation layers

~~~text
cluster
  │
  ▼
container
  │
  ▼
edge
  │
  ▼
observability
  │
  ▼
policies
  │
  ▼
end-to-end
~~~

Each layer proves a different contract.

## 3. Cluster validation

~~~text
make cluster-validate
        │
        ▼
3 Ready nodes
        │
        ▼
roles + private IPs
        │
        ▼
version / package pins
        │
        ▼
Pod + Service CIDRs
        │
        ▼
Calico networking
        │
        ▼
cross-node Pod traffic
        │
        ▼
dynamic local-path PVC
~~~

This validates the kubeadm/Ansible result, not merely the playbook exit
code.

## 4. Container validation

~~~text
make container-validate
        │
        ▼
build test stage
        │
        ▼
build runtime image
        │
        ▼
OCI source + revision
        │
        ▼
run container
        │
        ▼
HTTP query response
        │
        ▼
health endpoints
        │
        ▼
file log
        │
        ▼
Prometheus metrics
        │
        ▼
non-root runtime
        │
        ▼
no build tools/source
~~~

Optional registry push validation can also verify that the registry
returns an immutable SHA256 digest.

## 5. Edge smoke vs deep validation

~~~text
make edge-smoke
      │
      ▼
normal-path health


make edge-validate
      │
      ▼
host network boundary
      │
      ▼
Vault TLS / Raft / audit
      │
      ▼
BIND authoritative only
      │
      ▼
unsigned update rejected
      │
      ▼
ExternalDNS integration
      │
      ▼
HTTPS ingress
~~~

Deep edge validation deliberately exercises trust and network boundaries.

It also checks that the control plane has no edge NIC and that private
control-plane ports are not exposed through worker edge addresses.

## 6. Observability smoke

~~~text
make observability-smoke
        │
        ▼
workloads ready
        │
        ▼
PVCs bound
        │
        ▼
alert rule loaded
        │
        ▼
DNS + TLS endpoints
        │
        ▼
Elasticsearch healthy
        │
        ▼
Fluent Bit wrote index
~~~

This proves the log path reached Elasticsearch.

## 7. Policy smoke

~~~text
make policies-smoke
        │
        ▼
webhook rollout
        │
        ▼
immutable digest
        │
        ▼
replica spread
        │
        ▼
TLS / caBundle
        │
        ▼
fail-closed config
        │
        ▼
server dry-run decisions
~~~

The dry-runs execute the real API server, Service/TLS path, and webhook
code without persisting test Deployments.

## 8. End-to-end path

~~~text
make e2e-validate
      │
      ▼
cluster validation
      │
      ▼
edge validation
      │
      ▼
observability smoke
      │
      ▼
policy admission
      │
      ▼
Jenkins
      │
      ▼
application
      │
      ▼
metrics + log delivery
      │
      ▼
complete platform PASS
~~~

The final check crosses subsystem boundaries instead of repeating only
local health checks.

## 9. Jenkins checks

~~~text
Jenkins
   │
   ├── required Secrets exist
   ├── controller Ready
   ├── controller on node-3
   ├── PVC Bound
   ├── ingress present
   ├── DNS → ingress VIP
   ├── HTTPS login works
   └── numExecutors == 0
~~~

This proves the controller is persistent, reachable, correctly placed,
and not being used as a build executor.

## 10. Application checks

The validator reads the deployed replica count from the cluster instead
of hard-coding four replicas.

~~~text
current environment release
          │
          ▼
all replicas Ready
          │
          ▼
immutable image digest
          │
          ▼
runtime security
          │
          ▼
PDB rule
          │
          ▼
worker placement
          │
          ▼
DNS + HTTPS
          │
          ▼
request ID in app.log
~~~

Replica behavior follows the active environment profile:

~~~text
dev / stage
1 replica
no PDB


base / prod
4 replicas
spread across node-2 + node-3
PDB must leave a Pod evictable
~~~

For any multi-replica environment, the validator requires running Pods
across both workers.

## 11. End-to-end request evidence

~~~text
generate request ID
        │
        ▼
HTTPS /api/foos
        │
        ▼
correct response
        │
        ▼
same ID in app.log
        │
        ▼
same ID in Elasticsearch
~~~

One request ID ties the HTTP path and the log-delivery path together.

The orchestrator passes that value explicitly instead of hiding it in
ambient state.

## 12. Metrics evidence

~~~text
application ServiceMonitor
        │
        ▼
Prometheus target UP
        │
        ▼
JVM heap metric present
        │
        ▼
Grafana dashboards exist
        │
        ▼
app-logs datasource exists
~~~

This verifies both collection and dashboard provisioning.

## 13. Command map

| Path | Command | Purpose |
|---|---|---|
| `cluster/` | `make cluster-validate` | Kubernetes foundation |
| `container/` | `make container-validate` | image/runtime contract |
| `edge/` | `make edge-smoke` | normal edge health |
| `edge/` | `make edge-validate` | deep edge integration |
| observability | `make observability-smoke` | metrics/log platform |
| policies | `make policies-smoke` | admission behavior |
| `e2e/` | `make e2e-validate` | complete platform |

## 14. Failure rule

~~~text
validator finds failure
        │
        ▼
stop
        │
        ▼
identify owning subsystem
        │
        ▼
repair desired state there
        │
        ▼
reconcile
        │
        ▼
rerun validator
~~~

A validator may clean up only temporary resources that it created.

It must not mutate platform state to make its own check pass.
