# Infrastructure

`infra/` owns machine creation, the Kubernetes foundation, and host-side edge services. Kubernetes-resident edge components stay under [`platform/edge/`](../platform/edge/README.md).

Canonical design: [01 — Foundation](../docs/01-foundation/README.md) and [02 — Edge and trust](../docs/02-edge-trust/README.md).

## Ownership boundary

```text
Vagrant / VirtualBox
        │ creates VMs
        ▼
infra/ansible/
        │ provisions OS + Kubernetes
        ▼
running Kubernetes

infra/edge/
   │
   ├──► host Vault / BIND9 / CA / resolver
   └──► coordinates platform/edge/ reconciliation
```

## Cluster topology

```text
                  Kubernetes private network · 10.50.0.0/24

node-1                      node-2                      node-3
control plane               worker                      worker
10.50.0.10                  10.50.0.11                 10.50.0.12
                                │                           │
                         192.168.56.11               192.168.56.12
                                │                           │
                                └──────────┬────────────────┘
                                           ▼
                              host-only edge · 192.168.56.0/24
```

The control plane has no host-edge NIC. Cluster networks are explicit:

| Plane | CIDR |
|---|---|
| VM | `10.50.0.0/24` |
| Pod | `10.60.0.0/16` |
| Service | `10.70.0.0/16` |
| edge | `192.168.56.0/24` |

## Provisioning

A single **host-side Vagrant Ansible provisioner** is attached to the `node-3` machine definition and starts after all three VMs exist.

```text
3 VMs ready
    │
    ▼
infra/ansible/site.yml
    │
    ├──► common OS state
    ├──► containerd
    ├──► Kubernetes packages
    ├──► kubeadm control plane
    ├──► worker joins
    ├──► Calico
    └──► local-path storage
```

Create and validate:

```bash
make cluster-up
make cluster-validate
```

Reconcile an existing cluster:

```bash
vagrant provision node-3
```

An SSH-only repair is diagnostic. Permanent state belongs in the owning role.

## VM resources

| Node | CPU | RAM |
|---|---:|---:|
| node-1 | 2 | 2048 MiB |
| node-2 | 2 | 2048 MiB |
| node-3 | 2 | 4096 MiB |

Overrides: `MASTER_MEMORY`, `NODE_2_MEMORY`, `WORKER_MEMORY`, `MASTER_CPUS`, `WORKER_CPUS`.

`node-3` is larger because Jenkins and the dedicated CI/CD agents run there.

## Host edge

`infra/edge/` coordinates the host side of DNS, trust, and secret delivery.

```text
Vault · edge/dns/tsig ──► Vault Agent ──► BIND9 TSIG runtime file
          │
          └──────────────► VSO ──► ExternalDNS TSIG Secret

ExternalDNS ── signed RFC2136 ──► BIND9

local CA ──► wildcard TLS cert ──► Vault ──► VSO ──► ingress TLS Secret
```

First bootstrap:

```bash
make edge-up
```

Normal operation:

```bash
make edge-up
make edge-smoke
```

If Vault was sealed by a host reboot or service restart, `edge-up` unseals it
from the retained local-lab operator state and continues without a prompt.

Deep integration check:

```bash
make edge-validate
```

## Network safety

`Vagrantfile` rejects host-route/address conflicts on `192.168.56.0/24` and VirtualBox DHCP overlap with the MetalLB range before VM startup.

MetalLB automatic allocation is disabled for the edge pool. The ingress Service explicitly uses `192.168.56.200`.

## Operator-held state

Vault init output, unseal material, Vault root tokens, the CA private key, AppRole SecretIDs, GitHub tokens, and Docker Hub tokens stay outside Git.

## Paths

| Path | Responsibility |
|---|---|
| `ansible/site.yml` | cluster provisioning entry point |
| `ansible/group_vars/all.yml` | cluster network/version variables |
| `ansible/roles/` | cluster and host service roles |
| `ansible/playbooks/edge-host.yml` | host edge reconciliation |
| `edge/bin/up` | end-to-end edge reconcile |
| `edge/bin/down` | remove edge releases without deleting Vault data |
| `edge/bin/vault-init` | one-time Vault initialization |
| `edge/bin/vault-unseal` | operator unseal action |
| `edge/lib/` | Vault, Kubernetes tunnel, and VSO helpers |
