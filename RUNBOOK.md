# Runbook

Run commands from the repository root.

## 1. Full bring-up

A new host needs the tools first. See
[Host requirements](README.md#host-requirements).

~~~text
make prerequisites
      │
      ▼
make cluster-up
      │
      ▼
make cluster-validate
      │
      ▼
make edge-up
      │
      ├──── first build ───► make edge-validate
      │
      └──── normal run ────► make edge-smoke
      │
      ▼
load .env into Vault
(first build, §4)
      │
      ▼
make jenkins-up
      │
      ▼
make environment-up
      │
      ▼
make observability-up
      │
      ▼
make observability-smoke
      │
      ▼
wait for app release
in state/dev.yaml
      │
      ▼
make policies-up
      │
      ▼
make policies-smoke
      │
      ▼
make e2e-validate
~~~

## 2. Cluster

Create or reconcile the three VMs and Kubernetes:

~~~bash
make cluster-up
~~~

Validate:

~~~bash
make cluster-validate
~~~

Expected topology:

~~~text
node-1
CONTROL PLANE
10.50.0.10
    │
    ├──────────────┐
    ▼              ▼
node-2           node-3
WORKER           WORKER
10.50.0.11       10.50.0.12
~~~

For cluster details, see
**[infra/README.md](infra/README.md)**.

## 3. Edge

Reconcile host trust, DNS, ingress, MetalLB, ExternalDNS, and VSO:

~~~bash
make edge-up
~~~

First complete build:

~~~bash
make edge-validate
~~~

Normal health check:

~~~bash
make edge-smoke
~~~

~~~text
Vault / BIND9 / CA
        │
        ▼
VSO / ExternalDNS
        │
        ▼
MetalLB / ingress
        │
        ▼
managed HTTPS
~~~

For edge details, see
**[infra/edge/README.md](infra/edge/README.md)**.

## 4. CI credentials

The credentials live in `.env` at the repository root. Git ignores it.
Start from the template:

~~~bash
cp .env.example .env    # then fill in the values
~~~

The commands at the top of `.env` load it into Vault. Run them after
`make edge-up`. `make jenkins-up` and `make environment-up` stop with a
clear message when a path is missing.

~~~text
CI credentials
      │
      ▼
Vault
      │
      ▼
Jenkins


runtime registry credential
      │
      ▼
Vault
      │
      ▼
application namespace
~~~

## 5. Jenkins

Reconcile Jenkins:

~~~bash
make jenkins-up
~~~

Then prepare this cluster's application environment:

~~~bash
make environment-up
~~~

~~~text
Jenkins
   │
   ▼
dynamic agents
   │
   ├── build / scan
   └── deploy
          │
          ▼
      apps-dev
~~~

For Jenkins details, see
**[platform/jenkins/README.md](platform/jenkins/README.md)**.

## 6. Observability

Reconcile:

~~~bash
make observability-up
~~~

Smoke test:

~~~bash
make observability-smoke
~~~

~~~text
metrics
  │
  ▼
Prometheus ──► Grafana
  │
  └─────────► Alertmanager

logs
  │
  ▼
Fluent Bit ──► Elasticsearch
~~~

For observability details, see
**[platform/observability/README.md](platform/observability/README.md)**.

## 7. Wait for the application release

Jenkins CI records the released application in:

~~~text
state/dev.yaml
~~~

The expected shape is:

~~~yaml
sample-java-app:
  version: <version>
  image: sha256:<digest>
~~~

Do not continue to the policy/e2e stage until the application release is
present and deployed.

## 8. Policies

Install every registered policy from this cluster's environment state:

~~~bash
make policies-up
~~~

Verify:

~~~bash
make policies-smoke
~~~

~~~text
Deployment request
       │
       ▼
Kubernetes API
       │
       ▼
resource request webhook
       │
   ┌───┴────┐
   │        │
allow      deny
~~~

For policy details, see
**[policies/README.md](policies/README.md)**.

## 9. Final validation

Run:

~~~bash
make e2e-validate
~~~

~~~text
cluster
   │
   ▼
edge
   │
   ▼
Jenkins
   │
   ▼
application
   │
   ▼
metrics + logs
   │
   ▼
admission policy
   │
   ▼
PASS
~~~

The validator checks observable outcomes. It does not repair the system.

## 10. Useful access

Show platform endpoints:

~~~bash
make endpoints
~~~

Show operator-facing credentials:

~~~bash
make credentials
~~~

## 11. Normal repeat run

For an already-built environment:

~~~text
make cluster-up
      │
      ▼
make cluster-validate
      │
      ▼
make edge-up
      │
      ▼
make edge-smoke
      │
      ▼
make jenkins-up
      │
      ▼
make environment-up
      │
      ▼
make observability-up
      │
      ▼
make observability-smoke
      │
      ▼
make policies-up
      │
      ▼
make policies-smoke
      │
      ▼
make e2e-validate
~~~

## 12. Where to go next

- Infrastructure: [infra/README.md](infra/README.md)
- Delivery: [DELIVERY.md](DELIVERY.md)
- Jenkins: [platform/jenkins/README.md](platform/jenkins/README.md)
- Observability:
  [platform/observability/README.md](platform/observability/README.md)
- Validation: [validation/README.md](validation/README.md)
- Whole runbook in a fresh VM: [test/README.md](test/README.md)
- Bugs found by those runs: [docs/bugs.md](docs/bugs.md)
- Known weaknesses: [docs/weaknesses.md](docs/weaknesses.md)
