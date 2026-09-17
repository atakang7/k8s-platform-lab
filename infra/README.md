# Infrastructure

`infra/` owns the machines, Kubernetes foundation, and host-side edge services.

## Topology

```text
┌──────────────────── private cluster · 10.50.0.0/24 ────────────────────┐
│                                                                        │
│  node-1                  node-2                  node-3                 │
│  control plane           worker                  worker                 │
│  10.50.0.10              10.50.0.11             10.50.0.12            │
│                           192.168.56.11           192.168.56.12         │
│                                                                        │
│  kubeadm · containerd · Calico 10.244.0.0/16 · Services 10.96.0.0/12  │
└────────────────────────────────────────────────────────────────────────┘
                            │
                            │ worker-only edge NICs
                            │
┌──────────────────── host-only edge · 192.168.56.0/24 ─────────────────┐
│ host 192.168.56.1            MetalLB pool 192.168.56.200-220           │
│ Vault · BIND9 · local CA      ingress VIP 192.168.56.200               │
└────────────────────────────────────────────────────────────────────────┘
```

The control plane is intentionally absent from the host-accessible edge network.

## Cluster

`infra/ansible/` is applied once for the whole cluster by the `node-3` Vagrant provisioner. Roles install the base OS configuration, containerd, Kubernetes packages, control plane, workers, Calico, and local-path storage.

```bash
make cluster-up
make cluster-validate
```

Default VM sizing is defined by `Vagrantfile`:

| Node | CPU | RAM |
|---|---:|---:|
| node-1 | 2 | 2048 MiB |
| node-2 | 2 | 2048 MiB |
| node-3 | 2 | 4096 MiB |

`MASTER_MEMORY`, `NODE_2_MEMORY`, `WORKER_MEMORY`, `MASTER_CPUS`, and `WORKER_CPUS` can override the defaults before VM creation.

Reapply the cluster configuration when required:

```bash
vagrant provision node-3
```

Do not use provisioning as a substitute for changing desired state in Git.

## Edge host

`infra/edge/` coordinates the host services required by the Kubernetes edge:

- Vault: secrets authority and Raft-backed state.
- BIND9: authoritative `lab.test` DNS zone.
- Vault Agent: renders the RFC2136 TSIG key for BIND.
- local CA: trusts Vault and `*.lab.test` TLS locally.
- systemd-resolved integration: routes only the lab DNS zone to BIND.

Shared addresses live in `edge/config.env`. Component versions live in `edge/versions.env`.

Normal reconciliation:

```bash
make edge-up
make edge-smoke
```

First initialization requires explicit operator actions:

```bash
make edge-up
VAULT_INIT_OUTPUT=/secure/path/vault-init.json make vault-init
make vault-unseal
make edge-up
```

Vault initialization output, root tokens, unseal material, CA private keys, AppRole SecretIDs, and registry/SCM credentials are operator state. They do not belong in Git.

## Network safety

The Vagrantfile checks the host before creating the edge network. Startup fails if `192.168.56.0/24` conflicts with an existing non-VirtualBox address/route or if VirtualBox DHCP overlaps the MetalLB range.

MetalLB automatic allocation is disabled for the edge pool. Exposure is explicit; the ingress controller owns `192.168.56.200`.

## Ownership

| Path | Responsibility |
|---|---|
| `ansible/site.yml` | Cluster-wide provisioning entry point |
| `ansible/group_vars/all.yml` | Kubernetes and network variables |
| `ansible/roles/` | Idempotent cluster and host service roles |
| `ansible/playbooks/edge-host.yml` | Host edge reconciliation |
| `edge/bin/up` | End-to-end edge bootstrap/reconcile |
| `edge/bin/down` | Remove edge releases without deleting Vault data |
| `edge/bin/vault-init` | One-time Vault initialization |
| `edge/bin/vault-unseal` | Operator unseal action |
| `edge/lib/` | Vault, Kubernetes tunnel, and VSO bootstrap helpers |

Kubernetes-side edge services are owned by [`platform/edge/`](../platform/README.md).