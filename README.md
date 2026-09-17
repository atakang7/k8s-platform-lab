# Lab Kubernetes Platform

This repository is the source of truth for the platform, application runtime, delivery path, and operating procedures.

The reference environment is a three-node Kubernetes cluster on Vagrant/VirtualBox. Cluster state is reconciled from Git. Runtime credentials stay in Vault and are materialized into Kubernetes only for the consumers that need them.

## Architecture

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ Host                                                                        │
│                                                                             │
│  Vault                 BIND9 / RFC2136                 Local CA              │
│  secrets authority     lab.test                 trusted TLS           │
│        │                       │                            │                 │
└────────┼───────────────────────┼────────────────────────────┼─────────────────┘
         │                       │                            │
         │              192.168.56.0/24 edge                 │
         │                       │                            │
┌────────┴───────────────────────┴────────────────────────────┴─────────────────┐
│ Kubernetes edge                                                             │
│                                                                             │
│  ExternalDNS     Vault Secrets Operator     MetalLB 192.168.56.200           │
│                                                │                            │
│                                      ingress-nginx ×2                       │
│                           ┌────────────────────┼───────────────────┐          │
│                           │                    │                   │          │
│                 app.lab.test  jenkins.lab.test  observability │
└───────────────────────────┼────────────────────┼───────────────────┼──────────┘
                            │                    │                   │
┌───────────────────────────┴────────────────────┴───────────────────┴──────────┐
│ Kubernetes 10.50.0.0/24                                                     │
│                                                                             │
│  node-1                    node-2                     node-3                  │
│  control plane             worker                     worker                  │
│  10.50.0.10                10.50.0.11                 10.50.0.12             │
│                            192.168.56.11              192.168.56.12          │
│                                                                             │
│  Calico 10.244.0.0/16  ·  Services 10.96.0.0/12  ·  local-path storage     │
└─────────────────────────────────────────────────────────────────────────────┘
```

Application delivery is separate from the Jenkins controller. The controller has zero executors; dedicated CI and CD agents run on `node-3`.

```text
GitHub main
    │
    │ SCM poll
    │
┌───┴──────────────────────────────────────────────┐
│ CI · lab-build                                │
│                                                 │
│ tests · lint · server dry-run · Ansible syntax │
│ BuildKit image · Trivy report · CycloneDX SBOM │
└──────────────────────────┬───────────────────────┘
                           │ immutable image digest
┌──────────────────────────┴───────────────────────┐
│ CD · lab-deploy                               │
│                                                 │
│ checkout exact commit · Ansible deploy          │
│ rollout wait · deployed-digest assertion        │
└──────────────────────────┬───────────────────────┘
                           │
                 sample-java-app · 4 replicas
                 evenly spread across workers
```

## Bootstrap order

Run commands from the repository root.

```bash
make cluster-up
make cluster-validate

make edge-up
VAULT_INIT_OUTPUT=/secure/path/vault-init.json make vault-init
make vault-unseal
make edge-up

# Load the operator-held GitHub and Docker Hub credentials into Vault.
# Exact paths and commands: docs/operations.md

make jenkins-up
make observability-up
make observability-smoke
```

Jenkins creates `lab-build` and `lab-deploy` from JCasC. Application releases go through those pipelines; CD accepts only `repository@sha256:...` image references.

The admission webhook is installed after its image is published. See [`policies/`](policies/README.md).

## Repository map

| Path | Owns |
|---|---|
| [`app/`](app/README.md) | Java application, container, Kubernetes runtime manifests, logging contract |
| [`infra/`](infra/README.md) | VMs, kubeadm cluster, CNI, storage, host DNS/Vault/CA edge |
| [`platform/`](platform/README.md) | Kubernetes edge, Jenkins, monitoring, logging |
| [`delivery/`](delivery/README.md) | CI/CD pipelines, build tooling, deployment automation |
| [`policies/`](policies/README.md) | Admission control and resource-request enforcement |
| [`validation/`](validation/README.md) | Outcome-based cluster, container, and edge checks |
| [`docs/`](docs/README.md) | Architecture, operations, decisions, capacity and release design |
| `Vagrantfile` | Reference VM topology and host/edge networking |
| `Makefile` | Stable operator entry points |

## Operating rules

- Git defines desired configuration. Reconcile from Git instead of preserving manual cluster edits.
- Vault is the authority for credentials. Secret values are not committed.
- CI produces the artifact; CD deploys the immutable registry digest from that CI run.
- The application does not schedule on the control plane and is spread across both workers.
- Jenkins build execution stays off the controller and on the dedicated `node-3` agents.
- Trivy runs before publish and produces the SBOM. Vulnerability findings are report-only by default unless `TRIVY_EXIT_CODE` is set to a failing value.
- Stage 9 capacity and canary manifests are design references. They are not part of the normal live deployment.

## Entry points

| Operation | Command |
|---|---|
| Create/reconcile cluster | `make cluster-up` |
| Validate cluster | `make cluster-validate` |
| Validate container | `make container-validate` |
| Reconcile edge | `make edge-up` |
| Edge smoke test | `make edge-smoke` |
| Full edge validation | `make edge-validate` |
| Reconcile Jenkins | `make jenkins-up` |
| Reconcile observability | `make observability-up` |
| Observability smoke test | `make observability-smoke` |
| Destroy VMs | `make destroy` |

For first bootstrap, recovery, secrets, and day-two commands, use [`docs/operations.md`](docs/operations.md).