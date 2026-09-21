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

The guest baseline is pinned to `ubuntu/focal64` version `20240821.0.1`. For an intentional alternate base image, override `IMAGE_NAME` and `IMAGE_VERSION` together; ordinary rebuilds should keep the repository defaults so the same commit starts from the same guest OS image.

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

GitHub and Docker Hub credentials are **not** required to create the cluster. They are required before CI/CD is enabled and must remain outside Git; setup step 3 below shows how they reach Vault.

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

### 3. Load external credentials

`make jenkins-up` stores the CI credentials in Vault from these variables when `secret/ci/github`, `secret/ci/dockerhub` and `secret/ci/cosign` are absent; later runs reuse Vault:

```bash
export GITHUB_USERNAME=... GITHUB_TOKEN=...          # contents, commit statuses, pull requests
export DOCKERHUB_USERNAME=... DOCKERHUB_TOKEN=...    # image and chart publication
export COSIGN_PASSWORD=... COSIGN_PRIVATE_KEY="$(cat cosign.key)"   # image signing
```

Create the signing key once with `cosign generate-key-pair`. Commit `cosign.pub` as `delivery/pipeline/resources/lab/delivery/cosign.pub` and keep `cosign.key` out of Git; the deploy job refuses images not signed with it.

The runtime image-pull credential is written once:

```bash
vault kv put secret/runtime/dockerhub username=... token=...
```

Do not commit tokens, generated Vault material, kubeconfigs, or private keys.

### 4. Reconcile platform services and the application environment

```bash
make jenkins-up
make environment-up
make observability-up
make observability-smoke
```

`make environment-up` prepares the `dev`, `stage` and `prod` namespaces. Jenkins then runs the `platform` job (base charts, platform checks), the service jobs (build, scan, publish, record the digest in `state/dev.yaml`) and the `deploy` job, which releases each environment to its `state/<name>.yaml`. Promote to `stage` and `prod` by pull request. See [delivery](delivery/README.md).

### 5. Install admission policies and run the final proof

```bash
make policies-up        # webhook digest from state/prod.yaml
make policies-smoke
make e2e-validate       # validates the prod release
```

See [policies](policies/README.md) and [validation](validation/README.md).

> **Teardown scope:** `make destroy` destroys the Vagrant VMs. Host-side Vault/BIND/CA state is deliberately retained for recovery; see [infra/edge](infra/edge/README.md) before treating a VM rebuild as a completely clean host reset.

## Documentation

Each component documents itself next to its code:

| Component | Purpose |
|---|---|
| [RUNBOOK](RUNBOOK.md) | operator procedures: reconcile, inspect, validate, recover, roll back, stop/destroy |
| [infra](infra/README.md) | machines, kubeadm cluster, networking, storage; host edge: DNS, CA, Vault |
| [platform](platform/README.md) | edge controllers, Jenkins, observability, application environment |
| [delivery](delivery/README.md) | CI/CD: pipeline library, deploy job, CI agent image |
| [charts/service](charts/service/README.md) | base chart services inherit |
| [app](app/README.md) | sample application: build, runtime, chart values |
| [policies](policies/README.md) | admission policies and their lifecycle |
| [validation](validation/README.md) | cluster, edge, container and end-to-end checks |
| [state](state/) | the image digests each environment runs; a commit here is a deploy |
