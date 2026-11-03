Part of [k8s-platform-lab](../README.md)

# Infrastructure

Vagrant creates the three Ubuntu VMs; Ansible installs Kubernetes, and edge scripts configure the host services.

## Run

From the repository root:

```sh
make prerequisites
make cluster-up
make cluster-validate
```

## Config

| Variable | Default | Use |
| --- | --- | --- |
| `IMAGE_NAME` | `ubuntu/focal64` | Vagrant box |
| `IMAGE_VERSION` | `20240821.0.1` | Box release |
| `MASTER_MEMORY` | `2048` | Control plane RAM, MB |
| `NODE_2_MEMORY` | `4096` | First worker RAM, MB |
| `WORKER_MEMORY` | `4096` | Second worker RAM, MB |
| `BASE_IP` | `10.50.0` | VM address prefix |

## Interfaces

| Path | Purpose |
| --- | --- |
| [Vagrantfile](../Vagrantfile) | VM topology and Ansible entry |
| [ansible/](ansible/README.md) | kubeadm, Calico and local storage |
| [edge/](edge/README.md) | DNS, Vault, TLS and ingress bootstrap |
| `infra/bin/prerequisites` | Ubuntu host package installation |

The VM network is `10.50.0.0/24`. Workers also use `192.168.56.11` and `192.168.56.12`.
