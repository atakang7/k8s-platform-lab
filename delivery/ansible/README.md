# Application deployment

`delivery/ansible/` owns the Kubernetes release reconciliation used by `lab-deploy`.

Input is one immutable image reference:

```text
repository@sha256:<digest>
```

## Flow

```text
validated IMAGE_REF
      │
      ▼
apply Fluent Bit ConfigMap
      │
      ▼
apply Service + Ingress
      │
      ▼
render Deployment locally
with app=<IMAGE_REF>
      │
      ▼
kubectl apply
      │
      ▼
wait for rollout
      │
      ▼
read live Deployment image
      │
      ├── exact match ──► success
      └── mismatch ─────► fail
```

The committed Deployment file is not rewritten with each release digest. Ansible renders the image override for the apply operation so source configuration stays stable while the release artifact stays immutable.

Run through Jenkins during normal operation. Syntax is checked by CI before publication:

```bash
ansible-playbook --syntax-check delivery/ansible/deploy.yml
```

Do not add mutable-tag deployment paths here. CD's release contract is the immutable digest produced by CI.