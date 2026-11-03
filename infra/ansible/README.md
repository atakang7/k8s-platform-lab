Part of [k8s-platform-lab](../../README.md)

# Ansible cluster

The Vagrant provisioner runs `site.yml` after the third VM starts.

## Run

```sh
make cluster-up
make cluster-validate
```

To rerun the provisioner directly:

```sh
vagrant provision node-3
```

## Config

| Variable | Default | Use |
| --- | --- | --- |
| `kubernetes_version` | `1.34.1` | kubeadm and kubelet |
| `pod_cidr` | `10.60.0.0/16` | Pod network |
| `service_cidr` | `10.70.0.0/16` | Cluster services |
| `control_plane_endpoint` | `10.50.0.10:6443` | API server |

All values are in [group_vars/all.yml](group_vars/all.yml).

## Interfaces

| Path | Purpose |
| --- | --- |
| [site.yml](site.yml) | Kubernetes playbook |
| [roles/](roles/) | containerd, Calico, kubeadm and local storage |
| [validate.yml](validate.yml) | Ansible validation |
| [playbooks/edge-host.yml](playbooks/edge-host.yml) | Host DNS and Vault roles |
