# Lab Platform

This repository is the source of truth for the local Kubernetes platform, application runtime, delivery path, admission policy, and operating procedures.

The reference environment is three Ubuntu VMs on Vagrant/VirtualBox. Kubernetes state is reconciled from Git. Credentials remain outside Git and are delivered from Vault to the consumers that require them.

## System layout

```text
                                      HOST

          ╔════════════════════════════════════════════════════════════╗
         ╱  Vault              BIND9                local CA          ╱│
        ╱   secret authority   lab.test      host trust       ╱ │
       ╚════════════════════════════════════════════════════════════╝  │
       │                         192.168.56.1                          │
       └─────────────────────────────┬─────────────────────────────────┘
                                     │
                                     │ host-only edge · 192.168.56.0/24
                                     ▼
          ╔════════════════════════════════════════════════════════════╗
         ╱  Kubernetes edge                                         ╱│
        ╱                                                            ╱ │
       ║  ExternalDNS ──RFC2136──► BIND9                              ║
       ║  Vault ──VSO────────────► runtime Secrets                    ║
       ║  MetalLB VIP 192.168.56.200 ──► ingress-nginx ×2             ║
       ╚═══════════════════════════════╤══════════════════════════════╝
                                       │
                                       │ HTTPS
                                       ▼
          ╔════════════════════════════════════════════════════════════╗
         ╱  Kubernetes · private VM network 10.50.0.0/24             ╱│
        ╱                                                            ╱ │
       ║                                                             ║
       ║  node-1                 node-2                 node-3        ║
       ║  control plane          worker                 worker        ║
       ║  10.50.0.10             10.50.0.11            10.50.0.12   ║
       ║                         192.168.56.11         192.168.56.12 ║
       ║                                                             ║
       ║  Calico Pods 10.244.0.0/16 · Services 10.96.0.0/12         ║
       ║  local-path storage                                           ║
       ╚══════════════════════════════════════════════════════════════╝
```

The control plane has no host-edge NIC. Only the workers are reachable from the host-only edge network.

## Traffic path

```text
client
  │
  │ DNS query
  ▼
BIND9 · lab.test
  │
  │ A = 192.168.56.200
  ▼
MetalLB VIP
  │
  ▼
ingress-nginx
  │
  ├──────────────► app.lab.test ──► Service ──► 4 app Pods
  │
  ├──────────────► jenkins.lab.test ──► Jenkins controller
  │
  └──────────────► observability.lab.test ──► Grafana/Prometheus/ES
```

ExternalDNS is not in the request path. It watches Kubernetes resources and writes DNS records to BIND through RFC2136. VSO is also control-plane plumbing: it reads Vault values and creates runtime Kubernetes Secrets.

## Delivery path

The Jenkins controller orchestrates only. It has zero executors. CI and CD run on separate Kubernetes agents pinned to `node-3`.

```text
GitHub main
    │
    │ SCM poll · 1 minute
    ▼
┌────────────────────────────────────────────────────────────┐
│ lab-build · lab-ci-runner                             │
│                                                            │
│ tests ─┐                                                   │
│ lint ──┼─► validation complete                             │
│ dry-run┤                                                   │
│ syntax ┘                                                   │
│        │                                                   │
│        ▼                                                   │
│ BuildKit local image ─► Trivy + CycloneDX SBOM             │
│        │                                                   │
│        ▼                                                   │
│ BuildKit push ─► repository@sha256:<digest>                │
└──────────────────────────────┬─────────────────────────────┘
                               │ digest + exact commit
                               │ asynchronous handoff
                               ▼
┌────────────────────────────────────────────────────────────┐
│ lab-deploy · lab-cd-runner                            │
│                                                            │
│ validate immutable inputs                                  │
│   ─► checkout exact commit                                 │
│   ─► Ansible apply                                         │
│   ─► rollout status                                        │
│   ─► assert live Deployment image == requested digest      │
└────────────────────────────────────────────────────────────┘
```

Trivy is report-only by default because `TRIVY_EXIT_CODE` defaults to `0`. The SBOM is still generated and archived before publication.

## Application runtime

```text
app.lab.test
        │
        ▼
 ingress-nginx
        │
        ▼
 sample-java-app Service :80
        │
        ▼
┌───────────────────────────────────────────────────────┐
│ sample-java-app Deployment · 4 replicas              │
│                                                       │
│ node-2                         node-3                 │
│ app + Fluent Bit              app + Fluent Bit       │
│ app + Fluent Bit              app + Fluent Bit       │
└───────────────────────────────────────────────────────┘
```

The Deployment excludes the control plane, uses topology spread with `maxSkew: 1`, and rolls with `maxUnavailable: 0`. Each Java Pod writes an asynchronous file log to a shared volume; its Fluent Bit sidecar ships that file to Elasticsearch.

## Build order

The production documentation is split by dependency, not by repository history.

| Stage | Layer | Documentation |
|---:|---|---|
| 1 | VM and Kubernetes foundation | [`docs/stage-01-foundation.md`](docs/stage-01-foundation.md) |
| 2 | Edge, DNS, TLS, and secrets | [`docs/stage-02-edge-trust.md`](docs/stage-02-edge-trust.md) |
| 3 | Jenkins and observability | [`docs/stage-03-platform-services.md`](docs/stage-03-platform-services.md) |
| 4 | Application runtime | [`docs/stage-04-application-runtime.md`](docs/stage-04-application-runtime.md) |
| 5 | CI/CD and artifact flow | [`docs/stage-05-delivery.md`](docs/stage-05-delivery.md) |
| 6 | Admission policy | [`docs/stage-06-admission-policy.md`](docs/stage-06-admission-policy.md) |
| 7 | Capacity and critical release strategy | [`docs/stage-07-capacity-release.md`](docs/stage-07-capacity-release.md) |
| 8 | Validation and clean rebuild | [`docs/stage-08-validation-rebuild.md`](docs/stage-08-validation-rebuild.md) |

[`docs/README.md`](docs/README.md) is the documentation index. [`docs/architecture.md`](docs/architecture.md), [`docs/design.md`](docs/design.md), and [`docs/operations.md`](docs/operations.md) provide the cross-cutting system map, decisions, and operator procedures.

## Bootstrap

Run from the repository root.

```bash
make cluster-up
make cluster-validate

make edge-up
VAULT_INIT_OUTPUT=/secure/path/vault-init.json make vault-init
make vault-unseal
make edge-up

# Load external SCM/registry credentials into the documented Vault paths.
# See docs/operations.md.

make jenkins-up
make observability-up
make observability-smoke
```

Application releases are performed by `lab-build` and `lab-deploy`. The admission webhook is installed after its image has been published; see [`policies/README.md`](policies/README.md).

## Repository ownership

| Path | Responsibility |
|---|---|
| [`infra/`](infra/README.md) | VMs, Kubernetes foundation, host Vault/BIND/CA/resolver |
| [`platform/`](platform/README.md) | cluster edge, Jenkins, monitoring, logging |
| [`app/`](app/README.md) | Java service, image, probes, runtime manifests, file logging |
| [`delivery/`](delivery/README.md) | CI, image build/scan/publish, CD, Ansible release |
| [`policies/`](policies/README.md) | admission control |
| [`validation/`](validation/README.md) | outcome-based checks |
| [`docs/`](docs/README.md) | architecture, operating model, decisions, staged build documentation |
| `Vagrantfile` | machine resources and networks |
| `Makefile` | stable operator entry points |

## Operator entry points

| Operation | Command |
|---|---|
| create/reconcile cluster | `make cluster-up` |
| validate cluster | `make cluster-validate` |
| validate container | `make container-validate` |
| reconcile edge | `make edge-up` |
| edge smoke | `make edge-smoke` |
| deep edge validation | `make edge-validate` |
| reconcile Jenkins | `make jenkins-up` |
| reconcile observability | `make observability-up` |
| observability smoke | `make observability-smoke` |
| destroy VMs | `make destroy` |

## Source-of-truth rules

- Permanent platform changes are made in Git and reconciled from Git.
- Vault is the credential authority. Secret values are not committed.
- CI produces the artifact; CD deploys the immutable digest from that CI run.
- A release is identified by Git commit SHA plus image digest.
- Manual `kubectl edit`, ad-hoc Helm changes, or manual Jenkins job configuration are diagnostic actions, not desired state.
- A working cluster is not proof of reproducibility. Reproducibility is proven by a clean rebuild using only this repository, documented operator inputs, and documented commands.