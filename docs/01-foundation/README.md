# 01 — Foundation

This layer creates the machines and the Kubernetes substrate. Everything above it assumes these nodes, addresses, CIDRs, runtime, CNI, and storage behavior already exist.

## Topology

```text
                         private cluster network · 10.50.0.0/24

        ┌────────────────────┐
       /                    /│
      / node-1             / │
     └────────────────────┘  │
     │ control plane       │  │
     │ 10.50.0.10          │  │
     │ kube-apiserver      │ /
     └────────────────────┘/

        ┌────────────────────┐          ┌────────────────────┐
       /                    /│         /                    /│
      / node-2             / │        / node-3             / │
     └────────────────────┘  │       └────────────────────┘  │
     │ worker             │  │       │ worker             │  │
     │ 10.50.0.11        │  │       │ 10.50.0.12        │  │
     │ 192.168.56.11     │ /        │ 192.168.56.12     │ /
     └────────────────────┘/         └────────────────────┘/
                 │                              │
                 └──────── worker edge NICs ────┘
```

The control plane is not attached to the host-facing edge network. Only workers carry the second `192.168.56.0/24` interface.

## Cluster construction

```text
Vagrant
   │ creates 3 Ubuntu VMs
   ▼
Ansible · one cluster-wide run from node-3
   │
   ├─ base OS + kernel settings
   ├─ containerd
   ├─ Kubernetes packages
   ├─ kubeadm control plane
   ├─ worker joins
   ├─ Calico
   └─ local-path provisioner
   ▼
3-node Kubernetes cluster
```

The reference versions and network ranges are declared in [`infra/ansible/group_vars/all.yml`](../../infra/ansible/group_vars/all.yml):

| Setting | Value |
|---|---|
| Kubernetes | `1.34.1` |
| Calico | `3.32.2` |
| VM network | `10.50.0.0/24` |
| Pod network | `10.244.0.0/16` |
| Service network | `10.96.0.0/12` |
| API endpoint | `10.50.0.10:6443` |

## Resource layout

| Node | Role | CPU | RAM |
|---|---|---:|---:|
| node-1 | control plane | 2 | 2048 MiB |
| node-2 | worker | 2 | 2048 MiB |
| node-3 | worker + platform workloads | 2 | 4096 MiB |

The asymmetric worker sizing is intentional. Jenkins and most control-plane-style platform services are pinned to node-3; Prometheus and application replicas also use node-2 so the cluster remains useful under a small fixed memory budget.

## Engineering choices

### One cluster-wide provisioner

The `node-3` Vagrant provisioner runs the Ansible cluster play once after all three machines exist. Kubernetes initialization is therefore ordered as one operation instead of three independent per-node provisioners racing each other.

### Custom cluster CIDRs

Pod and Service CIDRs are explicit kubeadm inputs. They are not inherited from a local-development distribution. Calico owns Pod networking and kube-proxy owns Service translation.

### Worker-only application placement

Application manifests explicitly exclude the control plane. This keeps user workload pressure away from the API server and makes the two workers the actual runtime capacity boundary.

### Local storage is deliberate

`local-path` provides dynamic PVCs without external storage infrastructure. Persistence survives Pod recreation but remains tied to the node holding the volume. This tradeoff is accepted for the reference environment and documented where stateful platform services use it.

### Network collision checks happen before boot

The `Vagrantfile` refuses startup when `192.168.56.0/24` conflicts with a host route/address or when VirtualBox DHCP overlaps the reserved MetalLB range. A broken edge network is rejected before VMs are created instead of debugged later inside Kubernetes.

## Operator interface

```bash
make cluster-up
make cluster-validate
```

`make cluster-up` is the normal create/reconcile entry point. `cluster-validate` checks the resulting system rather than only checking Ansible completion.

## Validation boundary

Foundation is healthy when all three nodes are Ready, cross-node Pod traffic works, the configured Pod/Service networks are active, and dynamic storage can bind and mount a volume.

Implementation: [`Vagrantfile`](../../Vagrantfile), [`infra/ansible/`](../../infra/ansible/), [`validation/cluster/`](../../validation/cluster/).
