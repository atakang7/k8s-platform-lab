# Kubernetes foundation

`infra/ansible/` owns the guest OS and Kubernetes foundation for all three VMs.

```text
Vagrant inventory
      │
      ▼
┌──────────────────────┐
│ site.yml             │
└──────────┬───────────┘
           │
           ├──► common OS state
           ├──► containerd
           ├──► Kubernetes packages
           ├──► kubeadm control plane
           ├──► worker join
           ├──► Calico
           └──► local-path storage
```

A single host-side Vagrant Ansible provisioner is attached to the `node-3` definition. It runs the cluster-wide play after all three machines exist.

## Reconcile

From repository root:

```bash
make cluster-up
```

Reapply to an existing environment:

```bash
vagrant provision node-3
```

Validate outcomes:

```bash
make cluster-validate
```

## Change rule

Roles must be safe to rerun. Existing initialized/joined nodes are reconciled rather than re-created during a normal provision.

The kubeadm bootstrap identity is intentionally **not** an in-place migration surface. Changes to one-time cluster identity such as `pod_cidr`, `service_cidr`, the control-plane endpoint, or the VM topology require a deliberate cluster rebuild instead of silently mutating an initialized cluster.

Calico and local-path keep a readable release version plus the exact upstream Git revision used for downloads. A moved upstream tag therefore cannot change a rebuild.

If a node needs a permanent manual fix, move that fix into the appropriate role and reprovision. SSH commands are diagnosis, not desired state.

## Key files

| Path | Purpose |
|---|---|
| `site.yml` | cluster-wide role order |
| `group_vars/all.yml` | Kubernetes/network pins, topology, and immutable upstream source revisions |
| `roles/common/` | base OS state |
| `roles/containerd/` | container runtime |
| `roles/kubernetes/` | Kubernetes packages/services |
| `roles/control_plane/` | kubeadm initialization |
| `roles/workers/` | worker join |
| `roles/calico/` | Pod networking |
| `roles/storage/` | local-path provisioner |
| `validate.yml` | cluster outcome validation |

Host edge roles are also stored here but are orchestrated separately by `infra/edge/`.