# Architecture

This document describes the deployed system and the control flows that create it. Build order and operating procedures are documented separately in [`docs/README.md`](README.md) and [`operations.md`](operations.md).

## Physical and network planes

```text
                                      HOST

          ╔════════════════════════════════════════════════════════════╗
         ╱  192.168.56.1                                             ╱│
        ╱  Vault · BIND9 · local CA · scoped resolver               ╱ │
       ╚═══════════════════════════════╤══════════════════════════════╝  │
                                       │ host-only edge
                                       │ 192.168.56.0/24
                  ┌────────────────────┴────────────────────┐
                  │                                         │
                  ▼                                         ▼
        ┌──────────────────┐                       ┌──────────────────┐
        │ node-2           │                       │ node-3           │
        │ worker           │                       │ worker           │
        │ 10.50.0.11       │                       │ 10.50.0.12       │
        │ 192.168.56.11    │                       │ 192.168.56.12    │
        └─────────┬────────┘                       └─────────┬────────┘
                  │                                         │
                  └────────────────────┬────────────────────┘
                                       │ private VM network
                                       │ 10.50.0.0/24
                                       ▼
                             ┌──────────────────┐
                             │ node-1           │
                             │ control plane    │
                             │ 10.50.0.10       │
                             │ no edge NIC      │
                             └──────────────────┘
```

| Network | CIDR | Purpose |
|---|---|---|
| VM | `10.50.0.0/24` | kubelet/API/node traffic |
| Pod | `10.244.0.0/16` | Calico workload network |
| Service | `10.96.0.0/12` | Kubernetes virtual services |
| edge | `192.168.56.0/24` | host-to-worker ingress/DNS path |

MetalLB reserves `192.168.56.200-220`; ingress-nginx explicitly owns `192.168.56.200`.

## Edge data path

```text
client
  │
  │ resolve app.lab.test
  ▼
┌─────────────────────┐
│ BIND9               │
│ 192.168.56.1        │
└──────────┬──────────┘
           │ A = 192.168.56.200
           ▼
┌─────────────────────┐
│ MetalLB             │
│ ingress VIP         │
└──────────┬──────────┘
           ▼
┌─────────────────────┐
│ ingress-nginx ×2    │
│ worker-spread       │
└──────────┬──────────┘
           │ TLS + host/path routing
           ├────────────► application Service
           ├────────────► Jenkins Service
           └────────────► observability Services
```

The Kubernetes API is not part of this request path and remains on the private network.

## DNS control path

```text
Ingress / LoadBalancer metadata
             │
             ▼
       ExternalDNS
             │
             │ RFC2136 + TSIG
             ▼
           BIND9
             │
             ▼
      lab.test zone
```

ExternalDNS receives its TSIG credential through Vault Secrets Operator. DNS records are generated from Kubernetes desired state rather than maintained by hand.

## Secret control path

```text
                         Vault
                           │
          ┌────────────────┼───────────────────┐
          │                │                   │
          ▼                ▼                   ▼
     edge DNS/TLS       Jenkins CI         application
          │                │                   │
          ▼                ▼                   ▼
  Vault Agent / VSO       VSO                  VSO
          │                │                   │
          ▼                ▼                   ▼
   BIND TSIG file     Jenkins Secrets    registry pull Secret
                       + admin creds
```

Vault is the value authority. Kubernetes Secrets are runtime materializations. The repository contains paths, policies, and delivery objects, not secret values.

## Application plane

```text
                          Service :80
                              │
                              ▼
             ┌────────────────────────────────┐
             │ sample-java-app Deployment     │
             │ replicas: 4                    │
             │ topology maxSkew: 1            │
             │ control plane excluded         │
             └──────────────┬─────────────────┘
                            │
               ┌────────────┴────────────┐
               ▼                         ▼
      ┌──────────────────┐      ┌──────────────────┐
      │ node-2           │      │ node-3           │
      │ app + sidecar    │      │ app + sidecar    │
      │ app + sidecar    │      │ app + sidecar    │
      └──────────────────┘      └──────────────────┘
```

Each Pod has a Java container and Fluent Bit sidecar. The application writes an asynchronous file log to a shared `emptyDir`; the sidecar sends that file to Elasticsearch.

## Delivery control plane

```text
GitHub main
    │
    ▼
Jenkins controller · node-3 · 0 executors
    │
    ├──────────────────────┐
    ▼                      ▼
lab-ci-runner       lab-cd-runner
    │                      │
    │ tests                │ validate digest/SHA
    │ config checks        │ exact commit checkout
    │ BuildKit             │ Ansible deployment
    │ Trivy + SBOM         │ rollout wait
    │ registry push        │ live digest assertion
    ▼                      │
image digest ──────────────┘
```

The CI/CD handoff is immutable: full Git SHA plus `repository@sha256:<digest>`.

## Observability plane

```text
Kubernetes metrics ─────────────► Prometheus ─────► Grafana
                                      │
                                      └────────────► AlertManager

container stdout/stderr ─► node Fluent Bit ─┐
                                             ├─► Elasticsearch ─► Grafana logs
application.log ─► Pod sidecar Fluent Bit ──┘
```

Prometheus, Elasticsearch, and Jenkins use local-path volumes. They survive Pod recreation but do not provide storage HA across worker loss.

## Admission plane

```text
Deployment CREATE/UPDATE
          │
          ▼
 Kubernetes API
          │ AdmissionReview HTTPS
          ▼
resource-requests-webhook
          │
          ├── CPU + memory request on every regular container → allow
          └── either missing                               → deny
```

The webhook fails closed for in-scope Deployments. System namespaces and the policy namespace are excluded to avoid bootstrapping deadlocks.

## Capacity and release overlays

The baseline application keeps four scheduled replicas. HPA can request additional replicas. When fixed cluster capacity is exhausted, higher application priority allows lower-priority restartable batch Pods to be preempted.

Critical releases use a second candidate Deployment/Service and ingress-nginx canary weighting. Traffic progresses through controlled percentages while the stable version remains available.

See [`stage-07-capacity-release.md`](stage-07-capacity-release.md).

## Ownership boundaries

| Layer | Source of truth |
|---|---|
| VM lifecycle/network | `Vagrantfile` |
| Kubernetes foundation | `infra/ansible/` |
| host Vault/BIND/CA/resolver | `infra/` |
| cluster edge | `platform/edge/` |
| Jenkins | `platform/jenkins/` |
| observability | `platform/observability/` |
| application runtime | `app/` |
| release automation | `delivery/` |
| admission control | `policies/` |
| outcome checks | `validation/` |