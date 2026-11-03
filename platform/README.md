# Platform

`platform/` owns the Kubernetes-resident shared services around the
application.

## 1. Platform map

~~~text
                    KUBERNETES

             ┌──────────────────┐
             │ application      │
             └────────┬─────────┘
                      │
        ┌─────────────┼──────────────┐
        │             │              │
        ▼             ▼              ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ edge         │ │ Jenkins      │ │ observability│
│ ingress/DNS  │ │ CI/CD control│ │ metrics/logs │
└──────┬───────┘ └──────┬───────┘ └──────┬───────┘
       │                │                 ▲
       │                ▼                 │
       │        ┌──────────────┐          │
       │        │ environment  │          │
       │        │ namespace    │          │
       │        │ deploy ID    │          │
       │        └──────┬───────┘          │
       │               │                  │
       └───────────────┴──────────────────┘
~~~

Host-side Vault, BIND9, and the local CA live under
**[infra/](../infra/README.md)**. This directory begins where those host
services hand control into Kubernetes.

## 2. Ownership boundaries

~~~text
HOST
 │
 ├── Vault
 ├── BIND9
 └── local CA
 │
 ▼
platform/edge
 │
 ├── VSO
 ├── ExternalDNS
 ├── MetalLB
 └── ingress-nginx
 │
 ▼
application namespace
 │
 ├── runtime Secret
 └── deploy identity
 │
 ▼
application
 │
 └── metrics + logs
     │
     ▼
platform/observability
~~~

Each subsystem has a narrow responsibility. The platform layer does not
own application source or release logic.

## 3. Environment boundary

Each cluster runs one environment selected in
[environments.yaml](../environments.yaml).

~~~text
environments.yaml
      │
      ▼
clusterEnvironment: dev
      │
      ▼
┌──────────────────────┐
│ make environment-up  │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ apps-dev namespace   │
├──────────────────────┤
│ jenkins-deploy-dev   │
├──────────────────────┤
│ registry pull Secret │
└──────────┬───────────┘
           ▼
state/dev.yaml
      │
      ▼
application release
~~~

Stage and prod are represented in Git as later promotion targets. This
lab cluster currently prepares and deploys only `dev`.

## 4. Edge path

~~~text
Service / Ingress
        │
        ▼
ExternalDNS
        │
        ▼
host BIND9
        │ DNS answer
        ▼
client
        │
        ▼
MetalLB VIP
        │
        ▼
ingress-nginx
        │
        ▼
application Service
~~~

**Deep dive:** [platform/edge/](edge/README.md)

## 5. Jenkins path

~~~text
GitHub
  │
  ▼
Jenkins controller
  │ schedules
  ▼
Kubernetes agents
  │
  ├── CI build / scan
  ├── light validation
  └── environment deploy
~~~

The controller owns orchestration only. Pipeline execution runs in
dynamic Kubernetes agent Pods.

**Deep dive:** [platform/jenkins/](jenkins/README.md)

## 6. Observability path

~~~text
application / nodes / ingress
            │
            ▼
       Prometheus
         │    │
         │    └────► Alertmanager
         ▼
       Grafana


container logs
     │
     ▼
 Fluent Bit
     │
     ▼
Elasticsearch
     │
     ▼
  Grafana
~~~

**Deep dive:** [platform/observability/](observability/README.md)

## 7. Reconcile order

~~~text
make edge-up
    │
    ▼
make jenkins-up
    │
    ▼
make environment-up
    │
    ▼
make observability-up
~~~

The order follows dependencies:

~~~text
network + trust
      │
      ▼
CI/CD control plane
      │
      ▼
environment identity
      │
      ▼
application support services
~~~

For the full operator sequence, use
**[RUNBOOK.md](../RUNBOOK.md)**.

## 8. Main paths

| Area | Responsibility |
|---|---|
| [`edge/`](edge/README.md) | DNS, ingress, VIP, runtime edge secrets |
| [`jenkins/`](jenkins/README.md) | CI/CD controller and agents |
| `environment/` | app namespace, deploy identity, registry Secret |
| [`observability/`](observability/README.md) | metrics, alerts, logs, dashboards |

Application runtime configuration lives in
**[app/](../app/README.md)**.

Release behavior lives in **[DELIVERY.md](../DELIVERY.md)**.
