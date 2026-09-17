# Stage 1 — VM and Kubernetes foundation

This stage creates the three machines and turns them into the Kubernetes substrate used by every later stage.

## Topology

```text
                         host / VirtualBox

        ┌──────────────────────────────────────────────┐
       /                                              /│
      /      private VM network · 10.50.0.0/24       / │
     └──────────────────────────────────────────────┘  │
     │                                                 │
     │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
     │  │ node-1       │  │ node-2       │  │ node-3       │
     │  │ control plane│  │ worker       │  │ worker       │
     │  │ 10.50.0.10   │  │ 10.50.0.11   │  │ 10.50.0.12   │
     │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
     │         │                 │                 │
     │         └─────────────────┼─────────────────┘
     │                           │
     │                Kubernetes cluster
     │                           │
     │      ┌────────────────────┼────────────────────┐
     │      │ containerd         │ kubeadm            │
     │      │ Calico             │ local-path storage │
     │      └────────────────────┴────────────────────┘
     │
     └─────────────────────────────────────────────────
```

Only the workers receive the host-accessible `192.168.56.0/24` NIC. The control plane remains on the private cluster network.

## Build strategy

`Vagrantfile` owns VM lifecycle, addresses, CPU, RAM, and the worker-only edge NICs. The final VM (`node-3`) runs the cluster-wide Ansible provisioner after all three machines exist.

`infra/ansible/site.yml` applies narrow roles in dependency order:

```text
base OS
  │
  ▼
containerd
  │
  ▼
Kubernetes packages
  │
  ├───────────────┐
  ▼               ▼
control plane   worker join
  │               │
  └───────┬───────┘
          ▼
       Calico
          │
          ▼
 local-path storage
```

The cluster uses explicit, non-overlapping networks:

| Plane | CIDR |
|---|---|
| VM | `10.50.0.0/24` |
| Pod | `10.244.0.0/16` |
| Service | `10.96.0.0/12` |
| Host edge | `192.168.56.0/24` |

The runtime is containerd with systemd cgroups. kubeadm initializes the control plane and generates the worker join path. Calico owns Pod networking. local-path provides dynamic PVCs for this single-host lab.

## Operator flow

```bash
make cluster-up
make cluster-validate
```

`make cluster-up` delegates to `vagrant up`. Reconciliation after a Git change can be forced with:

```bash
vagrant provision node-3
```

The provisioner is idempotent around already initialized/joined nodes. Do not repair long-lived state manually and then treat that repair as desired configuration.

## Resource strategy

Reference sizing is:

| Node | CPU | RAM |
|---|---:|---:|
| node-1 | 2 | 2048 MiB |
| node-2 | 2 | 2048 MiB |
| node-3 | 2 | 4096 MiB |

Environment overrides exist for deliberate local changes: `MASTER_MEMORY`, `NODE_2_MEMORY`, `WORKER_MEMORY`, `MASTER_CPUS`, and `WORKER_CPUS`.

The larger `node-3` footprint is intentional: Jenkins controller and dedicated CI/CD runners are pinned there. `node-2` carries application and observability load but remains smaller.

## Validation contract

`make cluster-validate` must prove outcomes, not only process existence:

```text
nodes Ready
   │
   ├── cross-node Pod networking works
   │
   ├── Service networking works
   │
   └── dynamic PVC provisioning works
```

A later stage may depend on the cluster only after these checks pass.

## Source paths

`Vagrantfile` defines machines and networking. `infra/ansible/` defines the cluster. `validation/cluster/` verifies the result.