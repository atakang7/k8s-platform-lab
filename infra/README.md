# Infrastructure

`infra/` owns machine creation, Kubernetes foundation, and host-side edge services.

Detailed stages:

- [`docs/stage-01-foundation.md`](../docs/stage-01-foundation.md)
- [`docs/stage-02-edge-trust.md`](../docs/stage-02-edge-trust.md)

## Ownership boundary

```text
                           HOST

       ┌───────────────────────────────────────────────┐
      /                                               /│
     /  Vagrant / VirtualBox                         / │
    └──────────────────┬────────────────────────────┘  │
                       │ creates VMs                    │
                       ▼                                │
          ┌──────────────────────────────┐              │
          │ infra/ansible/               │              │
          │ Kubernetes foundation        │              │
          └──────────────┬───────────────┘              │
                         │                              │
                         ▼                              │
               running Kubernetes                      │
                                                        │
       ┌──────────────────────────────┐                 │
       │ infra/edge/                  │                 │
       │ host Vault/BIND/CA/resolver  │                 │
       └──────────────┬───────────────┘                 │
                      │ feeds cluster edge              │
                      ▼                                 │
               platform/edge/                          │
```

Kubernetes-resident edge components belong under [`platform/edge/`](../platform/README.md), not `infra/`.

## Cluster topology

```text
               private VM network · 10.50.0.0/24

      ┌─────────────────┐
     / node-1          /│       control plane
    └─────────────────┘ │       10.50.0.10
    │ no edge NIC      │
    └──────────────────┘

      ┌─────────────────┐        ┌─────────────────┐
     / node-2          /│       / node-3          /│
    └─────────────────┘ │      └─────────────────┘ │
    │ worker           │       │ worker           │
    │ 10.50.0.11      │       │ 10.50.0.12      │
    │ 192.168.56.11   │       │ 192.168.56.12   │
    └──────────────────┘       └──────────────────┘
              │                         │
              └───────────┬─────────────┘
                          ▼
             host-only edge · 192.168.56.0/24
```

Cluster networks are fixed and non-overlapping:

| Plane | CIDR |
|---|---|
| VM | `10.50.0.0/24` |
| Pod | `10.244.0.0/16` |
| Service | `10.96.0.0/12` |
| edge | `192.168.56.0/24` |

## Provisioning flow

`node-3` owns the single cluster-wide Vagrant Ansible provisioner. During normal `vagrant up`, all machines are created before that provisioner applies `infra/ansible/site.yml`.

```text
Vagrant creates node-1 / node-2 / node-3
                 │
                 ▼
          Ansible site.yml
                 │
     ┌───────────┼────────────┐
     ▼           ▼            ▼
   common     containerd   Kubernetes packages
                               │
                      ┌────────┴────────┐
                      ▼                 ▼
                 control plane      worker join
                      │                 │
                      └────────┬────────┘
                               ▼
                            Calico
                               │
                               ▼
                       local-path storage
```

Create and validate:

```bash
make cluster-up
make cluster-validate
```

Reconcile an existing cluster from Git:

```bash
vagrant provision node-3
```

Do not keep an SSH-only repair as permanent state. Move the fix into the owning role and reprovision.

## VM resources

Reference sizing:

| Node | CPU | RAM |
|---|---:|---:|
| node-1 | 2 | 2048 MiB |
| node-2 | 2 | 2048 MiB |
| node-3 | 2 | 4096 MiB |

Overrides: `MASTER_MEMORY`, `NODE_2_MEMORY`, `WORKER_MEMORY`, `MASTER_CPUS`, `WORKER_CPUS`.

`node-3` is larger because Jenkins and the dedicated CI/CD agents run there.

## Host edge

`infra/edge/` coordinates Vault, BIND9, the local CA, Vault Agent, host resolver integration, and Kubernetes edge reconciliation.

```text
Vault
  │
  ├──► Vault Agent ──► /run TSIG file ──► BIND9
  │
  └──► VSO identities ──────────────────► Kubernetes Secrets

BIND9 ◄──────── RFC2136 ◄──────── ExternalDNS

local CA ──► host trust ──► Vault + *.lab.test HTTPS
```

Shared addresses live in `edge/config.env`; version pins live in `edge/versions.env`.

First bootstrap:

```bash
make edge-up
VAULT_INIT_OUTPUT=/secure/path/vault-init.json make vault-init
make vault-unseal
make edge-up
```

Normal reconcile:

```bash
make edge-up
make edge-smoke
```

Deep validation:

```bash
make edge-validate
```

## Network safety

`Vagrantfile` checks `192.168.56.0/24` before creating the edge network. Startup fails when a non-VirtualBox host address/route conflicts or when VirtualBox DHCP overlaps the reserved MetalLB range.

MetalLB automatic allocation is disabled for the edge pool. The ingress VIP is explicitly `192.168.56.200`.

## Operator-held state

The following never belong in Git: Vault init output, unseal material, Vault root tokens, CA private key, AppRole SecretIDs, GitHub tokens, and Docker Hub tokens.

The repository owns where those values are consumed and how they are delivered. The operator owns the values themselves.

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