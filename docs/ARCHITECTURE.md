# Architecture

The platform is easier to understand as four planes: **machine**, **edge**, **delivery**, and **telemetry**.

## 1 · Machine plane

```mermaid
flowchart TB
  subgraph HOST[Ubuntu operator host]
    VAGRANT[Vagrant + VirtualBox]
    BIND[BIND9<br/>192.168.56.1]
    VAULT[Vault + local CA<br/>192.168.56.1:8200]
  end

  subgraph PRIVATE[10.50.0.0/24 · private cluster network]
    N1[node-1<br/>control plane<br/>10.50.0.10]
    N2[node-2<br/>worker<br/>10.50.0.11]
    N3[node-3<br/>worker<br/>10.50.0.12]
  end

  subgraph EDGE[192.168.56.0/24 · host edge]
    E2[node-2 · .11]
    E3[node-3 · .12]
    VIP[MetalLB VIP<br/>.200]
  end

  VAGRANT --> N1
  VAGRANT --> N2
  VAGRANT --> N3
  N2 --- E2
  N3 --- E3
  BIND --> VIP
  VAULT --> E2
  VAULT --> E3
```

**Why two networks?** The Kubernetes control plane stays on the private VM network. Only worker nodes touch the host edge. The host can reach ingress and Vault does not require exposing control-plane ports on the edge.

| Plane | Address |
|---|---|
| VM | `10.50.0.0/24` |
| Pod | `10.60.0.0/16` |
| Service | `10.70.0.0/16` |
| host edge | `192.168.56.0/24` |
| ingress VIP | `192.168.56.200` |

Deep dive: [infra/README.md](../infra/README.md)

## 2 · Edge plane

```mermaid
flowchart LR
  C[Client] --> R[systemd-resolved]
  R --> B[BIND9<br/>lab.test]
  B --> VIP[192.168.56.200]
  VIP --> NG[ingress-nginx ×2<br/>node-2 + node-3]
  NG --> S[ClusterIP Service]
  S --> P[application pods]

  I[Ingress / Service metadata] --> E[ExternalDNS]
  E -->|RFC2136 + TSIG| B

  V[Vault] -->|VSO TLS| NG
  V -->|VSO TSIG| E
```

The edge has one public entry point for the lab: ingress-nginx. MetalLB allocates the VIP explicitly; ExternalDNS writes the matching DNS records; Vault supplies the secret material.

Deep dive: [edge](../infra/edge/README.md) · [cluster edge](../platform/edge/README.md)

## 3 · Delivery plane

```mermaid
flowchart TB
  GH[GitHub]
  J[Jenkins controller<br/>node-3]

  subgraph CI[CI · jenkins-ci]
    V[validate]
    B[BuildKit]
    T[Trivy + SBOM]
    C[Cosign]
  end

  REG[(Docker Hub / OCI)]
  STATE[(state/dev.yaml)]
  CD[CD Pod<br/>jenkins-deploy-dev]
  K8S[Kubernetes API]
  APP[sample-java-app]

  GH --> J --> V --> B --> T --> REG
  REG --> C
  C --> STATE
  STATE --> CD --> K8S --> APP
```

The invariant is simple:

```text
source ──► build once ──► scan ──► publish exact bytes ──► sign digest
                                                       │
                                                       ▼
                                               state/<env>.yaml
                                                       │
                                                       ▼
                                               deploy same digest
```

CI can dry-run Kubernetes writes but admission blocks real writes. CD receives an environment-specific ServiceAccount and no application Secret read permission.

Deep dive: [DELIVERY.md](../DELIVERY.md) · [Jenkins](../platform/jenkins/README.md)

## 4 · Secret plane

```mermaid
flowchart LR
  OP[operator input] --> V[Vault]
  V --> A[AppRole]
  A --> VSO[Vault Secrets Operator]

  VSO --> DNS[ExternalDNS TSIG Secret]
  VSO --> TLS[Ingress wildcard TLS Secret]
  VSO --> J[Jenkins credentials]
  VSO --> R[Runtime registry pull Secret]

  V --> VA[Vault Agent]
  VA --> B[BIND9 TSIG runtime file]
```

Private keys, root/unseal material, GitHub tokens, Docker Hub tokens, and runtime credentials are excluded from Git. Git stores policies and references; Vault stores the secret values.

## 5 · Telemetry plane

```mermaid
flowchart TB
  APP[Java application]
  K[Kubernetes / nodes]
  NGINX[ingress-nginx]

  APP -->|/actuator/prometheus| P[Prometheus]
  K --> P
  NGINX --> P
  P --> G[Grafana]
  P --> A[Alertmanager]

  APP -->|async app.log| FB1[Fluent Bit sidecar]
  K -->|container logs| FB2[Fluent Bit DaemonSet]
  FB1 --> ES[Elasticsearch]
  FB2 --> ES
  ES --> G
```

Prometheus is also a release-safety dependency: production canary evaluation queries ingress 5xx metrics before the stable release is updated.

Deep dive: [observability](../platform/observability/README.md)

## Source-of-truth boundaries

| Change | Source |
|---|---|
| VM shape / host networking | [`Vagrantfile`](../Vagrantfile) |
| Kubernetes version / CIDRs | [`infra/ansible/group_vars/all.yml`](../infra/ansible/group_vars/all.yml) |
| host trust / DNS / Vault | [`infra/`](../infra/README.md) |
| Kubernetes edge | [`platform/edge/`](../platform/edge/README.md) |
| Jenkins runtime + jobs | [`platform/jenkins/`](../platform/jenkins/README.md) |
| application runtime | [`app/chart/`](../app/README.md) |
| reusable service behavior | [`charts/service/`](../charts/service/README.md) |
| release identity | [`state/*.yaml`](../state/) |
| CI/CD behavior | [`delivery/`](../delivery/README.md) |
| admission | [`policies/`](../policies/README.md) |
| proofs | [`validation/`](../validation/README.md) |

## Failure boundaries

```text
bad source / lint / test / scan
  └── stops before publish

bad signature / promotion / dry-run
  └── stops before runtime change

failed Helm readiness
  └── Helm rollback-on-failure

failed Helm smoke test
  └── explicit runtime rollback

bad production canary
  └── canary removed; stable release untouched
```

The platform keeps desired state and recovery distinct: a runtime rollback protects service availability; Git is then fixed or reverted to restore the desired state.
