# DevOps Engineering Requirements

This repository builds a three-node local Kubernetes cluster, packages the supplied Java 11 application, and adds a controlled host-accessible edge. The application is not deployed to Kubernetes yet.

```text
Vagrant / VirtualBox
        ↓
3 Ubuntu VMs
        ↓
Ansible → containerd → kubeadm → Calico → local-path storage

Java source → Maven Wrapper → Docker image → Git SHA tag

Host Vault + BIND9 → edge-only MetalLB VIP → two ingress-nginx replicas
                       ↑ ExternalDNS + Vault Secrets Operator
```

## Start here

Requirements: Vagrant, VirtualBox, Ansible, Helm, kubectl, Docker, and Make. Docker is needed for container validation. Stage 3 additionally needs host sudo access and an available `192.168.56.0/24` VirtualBox host-only network.

| Command | Result |
|---|---|
| `make cluster-up` | Start and provision all three VMs |
| `make cluster-validate` | Check the running Kubernetes cluster |
| `make container-validate` | Build and exercise the Java image |
| `make validate` | Run both validations |
| `make edge-up` | Configure Vault, BIND, DNS, MetalLB, ingress, ExternalDNS, and VSO |
| `make edge-smoke` | Check live Stage 3 health, DNS, and trusted HTTPS |
| `make edge-validate` | Run deep Stage 3 security and integration checks |
| `make edge-down` | Stop the edge without deleting Vault storage |
| `make jenkins-up` | Deploy the Stage 4 Jenkins controller |
| `make observability-up` | Deploy the pinned Stage 5 monitoring and logging stack |
| `make observability-smoke` | Check Stage 5 workloads, endpoints, and log delivery |
| `make destroy` | Destroy the local VMs |

`vagrant up` remains the cluster entry point. Vault initialization and unseal are explicit operator steps; see [operations](docs/operations.md). The container validator needs a Git commit and `origin`, or explicit source metadata.

## Repository map

| Path | Responsibility |
|---|---|
| `Vagrantfile` | VM lifecycle, networking, and resources |
| `infra/ansible/` | OS and Kubernetes foundation |
| `infra/ansible/roles/{bind9,vault,vault_agent,local_ca,resolver}/` | Host edge configuration |
| `infra/edge/` | Edge entry points, pinned versions, and runtime helpers |
| `platform/edge/` | Kubernetes edge services |
| `platform/jenkins/` | Jenkins Helm, JCasC, and Vault secret resources |
| `platform/observability/` | Pinned charts, Elasticsearch, Fluent Bit, dashboard, alert, and ingress |
| `app/` | Supplied application and container build |
| `delivery/`, `policies/` | Reserved for delivery and policy work |
| `validation/` | Cluster and container outcome checks |
| `docs/` | [Architecture](docs/architecture.md), [design](docs/design.md), and [operations](docs/operations.md) |
