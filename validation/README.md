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
Calico running
        │
        ▼
cross-node Pod traffic
        │
        ▼
dynamic local-path volume
~~~

This validates the kubeadm/Ansible result, not merely the playbook exit
code.

## 4. Container validation

~~~text
make container-validate
        │
        ▼
build image (runs unit tests)
        │
        ▼
run container
        │
        ▼
HTTP query response
        │
        ▼
ready + metrics endpoints
        │
        ▼
non-root runtime
~~~

## 5. Edge smoke vs deep validation

~~~text
make edge-smoke
      │
      ▼
normal-path health


make edge-validate
      │
      ▼
control-plane ports not on the edge
      │
      ▼
Vault unsealed
      │
      ▼
BIND answers, rejects unsigned updates
      │
      ▼
Secrets synced from Vault
      │
      ▼
Ingress DNS + trusted HTTPS
~~~

Edge validation exercises the trust and network boundaries.

## 6. Observability smoke

~~~text
make observability-smoke
        │
        ▼
workloads ready
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
Jenkins over HTTPS
      │
      ▼
app runs the recorded release
      │
      ▼
one request → Elasticsearch
      │
      ▼
Prometheus scrapes the app
      │
      ▼
complete platform PASS
~~~

The final check crosses subsystem boundaries instead of repeating only
local health checks.

## 9. Command map

| Path | Command | Purpose |
|---|---|---|
| `cluster/` | `make cluster-validate` | Kubernetes foundation |
| `container/` | `make container-validate` | image/runtime contract |
| `edge/` | `make edge-smoke` | normal edge health |
| `edge/` | `make edge-validate` | deep edge integration |
| observability | `make observability-smoke` | metrics/log platform |
| policies | `make policies-smoke` | admission behavior |
| `e2e/` | `make e2e-validate` | complete platform |

## 10. Failure rule

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
