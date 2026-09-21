# Lab Kubernetes Platform

A production-style Kubernetes lab built as one connected system: infrastructure, edge networking, secrets, CI/CD, observability, admission control, and immutable application delivery.

## System map

~~~text
                                      DELIVERY PLANE
┌───────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                               │
│   ┌──────────────┐      source / PR       ┌──────────────────────┐                            │
│   │    GitHub    │ ─────────────────────► │       Jenkins        │                            │
│   └──────┬───────┘                        │ validate · build      │                            │
│          │                                │ test · scan · sign   │                            │
│          │                                └──────────┬───────────┘                            │
│          │                                           │                                        │
│          │                         publish exact OCI │                                        │
│          │                                           ▼                                        │
│          │                                ┌──────────────────────┐                            │
│          │                                │ Docker Hub / OCI     │                            │
│          │                                │ immutable digest     │                            │
│          │                                └──────────┬───────────┘                            │
│          │                                           │                                        │
│          │                                           │ digest                                 │
│          │                                           ▼                                        │
│          │                                ┌──────────────────────┐                            │
│          └───────────────────────────────►│  state/<env>.yaml   │                            │
│                    Git desired state      │ version + image SHA  │                            │
│                                           └──────────┬───────────┘                            │
│                                                      │ deploy exact release                   │
└──────────────────────────────────────────────────────┼────────────────────────────────────────┘
                                                       ▼
                                      KUBERNETES RUNTIME PLANE
┌───────────────────────────────────────────────────────────────────────────────────────────────┐
│   ┌────────────────────┐       admission       ┌──────────────────────────────────────────┐   │
│   │ Jenkins deploy job │ ────────────────────► │ Kubernetes API                           │   │
│   └────────────────────┘                       │ + resource-request validating webhook    │   │
│                                                └──────────────────┬───────────────────────┘   │
│                                                                   ▼                           │
│                                                ┌──────────────────────────────────────────┐   │
│                                                │ application release                      │   │
│                                                │ exact image digest + Helm chart          │   │
│                                                └──────────────────┬───────────────────────┘   │
│                                      ┌────────────────────────────┼───────────────────────┐   │
│                                      ▼                            ▼                       ▼   │
│                           ┌──────────────────┐          ┌──────────────────┐     ┌────────────┐│
│                           │ Service / Pods   │          │ ServiceMonitor   │     │ app log    ││
│                           │ health probes    │          │ Prometheus       │     │ file       ││
│                           └─────────┬────────┘          └─────────┬────────┘     └─────┬──────┘│
│                                     │                             ▼                    ▼       │
│                                     │                    ┌──────────────────┐   ┌────────────┐│
│                                     │                    │ Grafana          │   │ Fluent Bit ││
│                                     │                    │ dashboards       │   │ sidecar    ││
│                                     │                    └──────────────────┘   └─────┬──────┘│
│                                     │                                                ▼       │
│                                     │                                         ┌────────────┐│
│                                     │                                         │Elasticsearch││
│                                     │                                         └────────────┘│
└─────────────────────────────────────┼─────────────────────────────────────────────────────────┘
                                      │ application traffic
                                      ▼
                                           EDGE PLANE
┌───────────────────────────────────────────────────────────────────────────────────────────────┐
│   client                                                                                      │
│     │ lookup *.lab.test                                                                │
│     ▼                                                                                         │
│   ┌──────────────┐       A record       ┌──────────────────┐                 ┌──────────────┐ │
│   │    BIND9     │ ◄─────────────────── │   ExternalDNS    │                 │   MetalLB    │ │
│   │ authoritative│                      │ RFC2136 + TSIG    │                 │  .200-.220   │ │
│   └──────┬───────┘                      └─────────┬────────┘                 └──────┬───────┘ │
│          │                                        │ watches                         │         │
│          │ DNS answer                             │ Service/Ingress                 ▼         │
│          ▼                                        │                       ┌─────────────────┐ │
│   client ────────────────────────────────────────────────────────────────► │ ingress-nginx   │ │
│                                                                           │ HTTPS routing   │ │
│                                                                           └────────┬────────┘ │
└────────────────────────────────────────────────────────────────────────────────────┼──────────┘
                                                                                     ▼
                                                                                application
~~~

The system is deliberately split into three visible paths: **delivery**, **runtime**, and **edge traffic**. Secrets and trust form a fourth path underneath them.

## Secrets and trust

~~~text
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                               OPERATOR HOST                                                  │
│                                                                                             │
│   ┌──────────────┐       policies / values       ┌──────────────────────┐                   │
│   │    Vault     │ ─────────────────────────────► │ Vault Secrets       │                   │
│   │ Raft + TLS   │                                │ Operator             │                   │
│   └──────┬───────┘                                └──────────┬───────────┘                   │
│          │                                                   │                               │
│          │ TSIG                                              │ Kubernetes Secrets            │
│          ▼                                                   ▼                               │
│   ┌──────────────┐                                 ┌──────────────────────┐                   │
│   │ Vault Agent  │                                 │ Jenkins / ExternalDNS│                   │
│   └──────┬───────┘                                 │ registry pull creds  │                   │
│          │                                         │ signing material     │                   │
│          ▼                                         └──────────────────────┘                   │
│   ┌──────────────┐                                                                           │
│   │ BIND9 TSIG   │                                                                           │
│   └──────────────┘                                                                           │
└─────────────────────────────────────────────────────────────────────────────────────────────┘

Secrets do not live in Git.
Jenkins does not carry a deployment kubeconfig.
Environment deployment identities are namespace-scoped.
~~~

## Physical layout

~~~text
                               10.50.0.0/24
                         Kubernetes private network

        ┌─────────────────────────┐
        │ node-1                  │
        │ control plane           │
        │ 10.50.0.10              │
        │                         │
        │ kube-apiserver          │
        │ etcd                    │
        │ controller-manager      │
        │ scheduler               │
        └────────────┬────────────┘
                     │
          ┌──────────┴────────────────────────────┐
          │                                       │
          ▼                                       ▼
┌─────────────────────────┐             ┌─────────────────────────┐
│ node-2                  │             │ node-3                  │
│ worker                  │             │ worker                  │
│ 10.50.0.11              │             │ 10.50.0.12              │
│ edge: 192.168.56.11     │             │ edge: 192.168.56.12     │
│                         │             │                         │
│ application workloads   │             │ Jenkins controller      │
│ Prometheus              │             │ CI/CD execution         │
│ Elasticsearch           │             │ application workloads   │
└────────────┬────────────┘             └────────────┬────────────┘
             │                                       │
             └──────────────────┬────────────────────┘
                                ▼
                     192.168.56.0/24 edge network
                                │
                                ▼
                     MetalLB LoadBalancer VIP
                         192.168.56.200

Pod CIDR:      10.60.0.0/16
Service CIDR:  10.70.0.0/16
~~~

The control plane does not participate in edge traffic. Public application traffic enters through worker edge interfaces and the MetalLB ingress VIP.

## Request path

~~~text
GET https://app.lab.test/api/foos?val=hello
                         │
                         ▼
                ┌─────────────────┐
                │ BIND9           │
                │ authoritative   │
                └────────┬────────┘
                         │ app.lab.test
                         │        ↓
                         │  192.168.56.200
                         ▼
                ┌─────────────────┐
                │ MetalLB         │
                │ ingress VIP     │
                └────────┬────────┘
                         ▼
                ┌─────────────────┐
                │ ingress-nginx   │
                │ TLS + host path │
                └────────┬────────┘
                         ▼
                ┌─────────────────┐
                │ Service         │
                │ ClusterIP       │
                └────────┬────────┘
                         ▼
                ┌─────────────────┐
                │ Java Pod        │
                │ /api/foos       │
                └───────┬─────────┘
                        │
          ┌─────────────┴─────────────────────────────┐
          │                                           │
          ▼                                           ▼
┌─────────────────────┐                    ┌─────────────────────┐
│ HTTP response       │                    │ /var/log/app/...    │
│ QueryStringValue... │                    │ async rolling log   │
└─────────────────────┘                    └──────────┬──────────┘
                                                    ▼
                                           ┌─────────────────────┐
                                           │ Fluent Bit sidecar  │
                                           └──────────┬──────────┘
                                                      ▼
                                           ┌─────────────────────┐
                                           │ Elasticsearch       │
                                           │ app-logs            │
                                           └─────────────────────┘
~~~

## Release path

~~~text
                           PULL REQUEST
                                │
                                ▼
                  ┌───────────────────────────┐
                  │ Validate                  │
                  │ Dockerfile / chart        │
                  │ server dry-run            │
                  └────────────┬──────────────┘
                               ▼
                  ┌───────────────────────────┐
                  │ BuildKit                  │
                  │ build image once          │
                  │ unit tests in build       │
                  └────────────┬──────────────┘
                               ▼
                  ┌───────────────────────────┐
                  │ Trivy                     │
                  │ CRITICAL gate + SBOM      │
                  └────────────┬──────────────┘
                               │
                     merge to main
                               │
                               ▼
                  ┌───────────────────────────┐
                  │ publish SAME OCI bytes    │
                  │ verify registry digest    │
                  └────────────┬──────────────┘
                               ▼
                  ┌───────────────────────────┐
                  │ Cosign                    │
                  │ sign exact digest         │
                  └────────────┬──────────────┘
                               ▼
                  ┌───────────────────────────┐
                  │ state/dev.yaml            │
                  │ version + image digest    │
                  └────────────┬──────────────┘
                               ▼
                  ┌───────────────────────────┐
                  │ deploy job                │
                  │ signature + promotion     │
                  │ render + server dry-run   │
                  └────────────┬──────────────┘
                               ▼
                  ┌───────────────────────────┐
                  │ helm upgrade --wait       │
                  │ exact image digest        │
                  └────────────┬──────────────┘
                               ▼
                  ┌───────────────────────────┐
                  │ helm test / smoke         │
                  └────────────┬──────────────┘
                               │ healthy
                               ▼
                  ┌───────────────────────────┐
                  │ environment tag           │
                  │ dev-YYYY.MM.DD.N          │
                  └────────────┬──────────────┘
                               ▼
                  ┌───────────────────────────┐
                  │ promotion PR              │
                  │ dev → stage → prod        │
                  │ SAME version + digest     │
                  └───────────────────────────┘
~~~

The repository currently configures this lab cluster as **dev**. Stage and prod state describe the same promotion model for equivalent environment clusters.

## Observability path

~~~text
                              METRICS
┌─────────────────┐
│ application     │── /actuator/prometheus ──┐
└─────────────────┘                           │
                                              ▼
┌─────────────────┐                   ┌─────────────────┐
│ ingress-nginx   │── metrics ───────►│ Prometheus      │
└─────────────────┘                   └────────┬────────┘
                                              │
                           ┌───────────────────┼──────────────────┐
                           ▼                   ▼                  ▼
                  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
                  │ Grafana         │ │ Alert rules     │ │ canary health   │
                  │ dashboards      │ │ pod restart     │ │ 5xx signal      │
                  └─────────────────┘ └────────┬────────┘ └─────────────────┘
                                              ▼
                                     ┌─────────────────┐
                                     │ Alertmanager    │
                                     └─────────────────┘


                                LOGS
┌─────────────────┐
│ all containers  │── /var/log/containers ──► Fluent Bit DaemonSet ──► kubernetes-* index
└─────────────────┘

┌─────────────────┐
│ application     │── /var/log/app/app.log ──► Fluent Bit sidecar ──► app-logs index
│ async file log  │
└─────────────────┘
~~~

## Start here

~~~text
                         ┌──────────────────┐
                         │    README.md     │
                         │ system landing   │
                         └────────┬─────────┘
                                  │
                ┌─────────────────┼──────────────────┐
                │                 │                  │
                ▼                 ▼                  ▼
       ┌────────────────┐ ┌────────────────┐ ┌────────────────┐
       │ RUNBOOK.md     │ │ DELIVERY.md    │ │ component docs │
       │ operate        │ │ release flow   │ │ implementation │
       └────────────────┘ └────────────────┘ └────────────────┘
~~~

For a fresh environment:

~~~text
cluster-up
    │
    ▼
cluster-validate
    │
    ▼
edge-up ─────► edge-smoke
    │
    ▼
jenkins-up
    │
    ▼
environment-up
    │
    ▼
observability-up ─────► observability-smoke
    │
    ▼
policies-up
    │
    ▼
e2e-validate
~~~

Use **[RUNBOOK.md](RUNBOOK.md)** for exact commands, credentials, validation, recovery, and teardown.

## Repository map

| Area | Owns |
|---|---|
| [infra/](infra/README.md) | VMs, kubeadm cluster, Ansible, host DNS, Vault and trust |
| [platform/](platform/README.md) | Kubernetes edge, Jenkins, environment setup and observability |
| [delivery/](delivery/README.md) | Jenkins pipelines, shared delivery library and release scripts |
| [state/](state/) | desired version + image digest for each environment |
| [app/](app/README.md) | Java application, container image and service values |
| [charts/service/](charts/service/README.md) | reusable application runtime chart |
| [policies/](policies/README.md) | validating admission controls |
| [validation/](validation/README.md) | cluster, edge, platform and end-to-end proof |

## Deep dives

- **[RUNBOOK.md](RUNBOOK.md)** — build, operate, validate, recover.
- **[DELIVERY.md](DELIVERY.md)** — CI, immutable release state, deployment and promotion.
- **[Jenkins](platform/jenkins/README.md)** — controller, agents, credentials and jobs.
- **[Edge](infra/edge/README.md)** — BIND9, Vault, local CA and edge bootstrap.
- **[Observability](platform/observability/README.md)** — metrics, dashboards, alerting and logs.
- **[Resource request policy](policies/resource-requests-webhook/README.md)** — admission webhook behavior.
- **[CI agent image](delivery/jenkins/README.md)** — Jenkins execution image lifecycle.

## Host requirements

The complete environment is intended to run from an **Ubuntu x86_64** operator host with VirtualBox, Vagrant, Ansible, Kubernetes/Helm tooling, GNU Make, and the standard CLI utilities used by the repository.
