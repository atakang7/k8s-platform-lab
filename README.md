# Lab Kubernetes Platform

This repository is the source of truth for the infrastructure, Kubernetes platform, application runtime, delivery path, policy controls, and operating procedures. The environment is built from Git-managed configuration; credentials stay outside Git and are delivered from Vault to the consumers that need them.

```text
TRUST / SECRET CONTROL

local CA ──signs──► wildcard TLS cert ──stored in──► Vault
                                                         │
                                                         │ Vault API
                                                         ▼
                                              Vault Secrets Operator
                                                         │
                                                         ▼
                                                Kubernetes Secrets

DNS CONTROL

Kubernetes Ingress / Service state ──► ExternalDNS ──RFC2136 + TSIG──► BIND9
                                                                          │
                                                                          │ lab.test
                                                                          ▼
                                                                    DNS responses

HTTPS REQUEST PATH

client ──DNS lookup──► BIND9 ──A: 192.168.56.200──► client
                                                       │
                                                       │ HTTPS
                                                       ▼
                         MetalLB ──assigns/L2──► ingress Service · .200
                                                       │
                                                       ▼
                                              ingress-nginx ×2
                                                       │
                       ┌───────────────────────────────┼────────────────────┐
                       ▼                               ▼                    ▼
               sample-java-app                    Jenkins           observability
               4 replicas                         controller        metrics + logs
               node-2 / node-3                    node-3 · 0 execs
                                                       │
                                                       ▼
                                                  CI/CD agents
                                                  node-3

NODE PLACEMENT

node-1                      node-2                      node-3
control plane               worker                      worker
10.50.0.10                  10.50.0.11                 10.50.0.12
                            192.168.56.11               192.168.56.12
```


## Prerequisites

The full environment is supported from an **Ubuntu x86_64 operator host**. VM creation may work on other systems, but the complete bootstrap intentionally runs host-side Ansible and refuses non-Ubuntu or non-x86_64 hosts because it configures BIND9, Vault, the local CA, and split DNS on the operator machine.

| Requirement | Purpose |
|---|---|
| sudo access | host DNS, Vault, CA, resolver, and trust-store configuration |
| VirtualBox (`VBoxManage`) + Vagrant | create the three VMs and the host-only edge network |
| Ansible (`ansible-playbook`) | provision Kubernetes and reconcile host-side edge services |
| `kubectl` + Helm | reconcile Kubernetes-resident edge and platform components |
| Git, GNU Make, Bash, Python 3, OpenSSH, `ip`, `curl`, `jq`, OpenSSL | orchestration and validation helpers |
| Internet access | Vagrant box, package repositories, container registries, and Helm repositories |

The edge reconciliation installs the host Vault CLI and DNS utilities used by later validation. Host tool versions are not duplicated here; component versions owned by the repository are pinned in the corresponding `versions.env`, Ansible variables, manifests, or chart configuration.

The default VM plan allocates **6 vCPUs and 8 GiB RAM** in total:

| Node | Role | CPU | RAM |
|---|---|---:|---:|
| node-1 | control plane | 2 | 2048 MiB |
| node-2 | worker | 2 | 2048 MiB |
| node-3 | worker + platform workloads | 2 | 4096 MiB |

Leave additional capacity for the Ubuntu host and VirtualBox. The host-facing network `192.168.56.0/24` must be available; `192.168.56.200-220` is reserved for MetalLB. The `Vagrantfile` checks host routes, addresses, and VirtualBox DHCP overlap before boot and fails early on a collision.

A quick host check before creating anything:

```bash
for cmd in sudo git make vagrant VBoxManage ansible-playbook kubectl helm python3 ssh ip curl jq openssl; do
  command -v "$cmd" >/dev/null || echo "missing: $cmd"
done
```

GitHub and Docker Hub credentials are **not** required to create the cluster. They are required before CI/CD is enabled and must remain outside Git; the supported Vault paths and exact loading commands are documented in [07 — Operations and validation](docs/07-operations-validation/README.md#3-external-credentials).

## Fresh setup

Run all commands from the repository root. `make edge-up` initializes and unseals
the local lab Vault automatically. Its root-of-trust file is retained outside
the repository at `${XDG_DATA_HOME:-$HOME/.local/share}/lab-operator/vault-init.json`.

### 1. Create and validate the Kubernetes foundation

```bash
make cluster-up
make cluster-validate
```

### 2. Bootstrap edge, trust, and Vault

```bash
make edge-up
```

For the **first build**, run the deep edge validation once. It proves
ExternalDNS create/delete behavior beyond the retained health endpoint managed
by `edge-up`:

```bash
make edge-validate
make edge-smoke
```

Later reconciliations normally use `make edge-up && make edge-smoke`.

### 3. Load external delivery credentials

Populate the three documented Vault paths for GitHub CI access, Docker Hub publication, and runtime image pulls:

- `secret/ci/github`
- `secret/ci/dockerhub`
- `secret/runtime/dockerhub`

Use the exact commands in [External credentials](docs/07-operations-validation/README.md#3-external-credentials). Do not commit tokens, generated Vault material, kubeconfigs, or private keys.

### 4. Reconcile platform services and runtime registry identity

```bash
make jenkins-up
make observability-up
make observability-smoke
./app/k8s/bootstrap-registry-auth.sh
```

Trigger the Jenkins `lab-build` job to build, scan, publish, and hand the immutable image digest to `lab-deploy`.

### 5. Install the admission policy and run the final proof

The admission webhook image must be published first and installed with its immutable digest. Follow [Admission policy](docs/06-governance-resilience/admission-policy.md), then run:

```bash
make e2e-validate
```

The full bootstrap, recovery, external-secret, policy-installation, and validation details live in [07 — Operations and validation](docs/07-operations-validation/README.md).

> **Teardown scope:** `make destroy` destroys the Vagrant VMs. Host-side Vault/BIND/CA state is deliberately retained for recovery; see the operations guide before treating a VM rebuild as a completely clean host reset.

## Documentation

| Layer | Purpose |
|---|---|
| [01 — Foundation](docs/01-foundation/README.md) | machines, kubeadm cluster, networking, storage, resource layout |
| [02 — Edge and trust](docs/02-edge-trust/README.md) | DNS, TLS, Vault, secret delivery, ingress, LoadBalancer edge |
| [03 — Platform services](docs/03-platform-services/README.md) | Jenkins and observability services |
| [04 — Application runtime](docs/04-application-runtime/README.md) | container build, probes, placement, rollout, logging |
| [05 — Delivery](docs/05-delivery/README.md) | CI, BuildKit, scanning, immutable artifacts, CD |
| [06 — Governance and resilience](docs/06-governance-resilience/README.md) | admission policy, fixed-capacity scheduling, canary releases |
| [07 — Operations and validation](docs/07-operations-validation/README.md) | bootstrap, secrets, recovery, validation, clean rebuild |

[`docs/README.md`](docs/README.md) explains the documentation structure and implementation ownership.
