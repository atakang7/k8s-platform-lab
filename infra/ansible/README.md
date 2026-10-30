# Kubernetes foundation

`infra/ansible/` owns guest OS configuration and the Kubernetes
foundation for all three VMs.

## 1. Provisioning model

~~~text
                   VAGRANT

             ┌──────────────────┐
             │ node-1 created   │
             └────────┬─────────┘
                      │
             ┌────────▼─────────┐
             │ node-2 created   │
             └────────┬─────────┘
                      │
             ┌────────▼─────────┐
             │ node-3 created   │
             └────────┬─────────┘
                      │ all VMs exist
                      ▼
             ┌──────────────────┐
             │ host Ansible     │
             │ site.yml         │
             └────────┬─────────┘
                      ▼
                full cluster
~~~

Only one Vagrant Ansible provisioner runs the cluster-wide play. It is
attached to `node-3`, so provisioning starts after all three machines
exist.

## 2. Role order

~~~text
site.yml
  │
  ▼
┌────────────────────┐
│ common             │
│ OS prerequisites   │
└─────────┬──────────┘
          ▼
┌────────────────────┐
│ containerd         │
│ runtime            │
└─────────┬──────────┘
          ▼
┌────────────────────┐
│ kubernetes         │
│ packages + kubelet │
└─────────┬──────────┘
          ▼
┌────────────────────┐
│ control_plane      │
│ kubeadm init       │
│ node-1             │
└─────────┬──────────┘
          ▼
┌────────────────────┐
│ workers            │
│ kubeadm join       │
│ node-2 + node-3    │
└─────────┬──────────┘
          ▼
┌────────────────────┐
│ calico             │
│ Pod networking     │
└─────────┬──────────┘
          ▼
┌────────────────────┐
│ storage            │
│ local-path         │
└─────────┬──────────┘
          ▼
┌────────────────────┐
│ validation         │
│ expected topology  │
└────────────────────┘
~~~

The order is deliberate: workers join only after the control plane is
initialized; networking and dynamic storage are installed after the
cluster exists.

## 3. Cluster identity

~~~text
               CLUSTER NETWORKS

VM network       10.50.0.0/24
      │
      ├── node-1  10.50.0.10
      ├── node-2  10.50.0.11
      └── node-3  10.50.0.12

Pod CIDR         10.60.0.0/16
Service CIDR     10.70.0.0/16
~~~

These values are part of bootstrap identity, not ordinary runtime
configuration.

## 4. Reconcile path

~~~text
configuration change
        │
        ▼
vagrant provision node-3
        │
        ▼
┌──────────────────────┐
│ rerun site.yml       │
└──────────┬───────────┘
           │
     ┌─────┴─────┐
     │           │
     ▼           ▼
already       drifted
correct       state
     │           │
     │           ▼
     │      reconcile
     │           │
     └─────┬─────┘
           ▼
      desired state
~~~

Roles are written to converge existing nodes rather than recreate them
during normal provisioning.

Run:

~~~bash
vagrant provision node-3
~~~

Then verify:

~~~bash
make cluster-validate
~~~

## 5. Reconcile vs rebuild

~~~text
ordinary change
     │
     ▼
package / config /
service state
     │
     ▼
RECONCILE


bootstrap identity
     │
     ▼
Pod CIDR
Service CIDR
control-plane endpoint
VM topology
     │
     ▼
REBUILD
~~~

A normal Ansible run must not silently mutate one-time kubeadm identity.
Those changes require a deliberate cluster rebuild.

## 6. Network bring-up

~~~text
node-1
  │ kubeadm init
  ▼
control plane ready
  │
  ├───────────────┐
  │               │
  ▼               ▼
node-2 joins    node-3 joins
  │               │
  └───────┬───────┘
          ▼
      Calico
          │
          ▼
Pod-to-Pod networking
across both workers
~~~

Calico is pinned to a readable version and exact upstream source
revision so a moved upstream tag cannot alter a rebuild.

## 7. Storage bring-up

~~~text
Kubernetes
    │
    ▼
local-path provisioner
    │
    ▼
StorageClass
    │
    ▼
PVC request
    │
    ▼
local PV on owning node
~~~

The local-path provisioner provides dynamic volumes for this lab. It is
node-local storage, not cross-node storage HA.

## 8. Validation

~~~text
make cluster-validate
        │
        ▼
┌──────────────────────┐
│ 3 Ready nodes        │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ Calico running       │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ cross-node network   │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ dynamic PVC          │
└──────────────────────┘
~~~

Validation checks outcomes rather than merely checking that Ansible
finished successfully.

## 9. Main files

| Path | Responsibility |
|---|---|
| `site.yml` | cluster-wide role order |
| `group_vars/all.yml` | versions, CIDRs, topology pins |
| `roles/common/` | base OS state |
| `roles/containerd/` | container runtime |
| `roles/kubernetes/` | Kubernetes packages/services |
| `roles/control_plane/` | kubeadm initialization |
| `roles/workers/` | worker join |
| `roles/edge_firewall/` | closes the workers' own ports on the edge network |
| `roles/calico/` | Pod networking |
| `roles/storage/` | local-path provisioner |
| `validate.yml` | cluster outcome validation |

Host-edge Ansible roles also live here, but their lifecycle is owned by
**[infra/edge/](../edge/README.md)**.
