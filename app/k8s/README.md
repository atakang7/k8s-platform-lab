# Application Kubernetes runtime

`app/k8s/` defines the stable application runtime. Release automation consumes these manifests; it does not replace their ownership.

```text
deployment.yaml
    │
    ├──► 4 replicas
    ├──► worker-only placement
    ├──► topology spread
    ├──► probes + resources
    └──► Java + Fluent Bit sidecar

service.yaml ──► :80 → :9001

ingress.yaml ──► app.lab.test + wildcard TLS

registry-secret.yaml ◄── VSO ◄── Vault runtime/dockerhub
```

## Registry bootstrap

After Vault and VSO are healthy and `secret/runtime/dockerhub` contains `username` and `token`:

```bash
./app/k8s/bootstrap-registry-auth.sh
```

This creates the application Vault policy/AppRole, Kubernetes `VaultAuth`, and applies the VSO registry Secret declaration.

## Release behavior

Do not manually edit `deployment.yaml` to the latest pushed tag. Normal CD renders the `app` container image locally with the immutable digest passed from CI:

```text
source Deployment
      │
      + immutable IMAGE_REF
      ▼
kubectl set image --local
      │
      ▼
kubectl apply
```

The committed manifest stays readable and reusable; release identity comes from the CI digest.

## Validation

CI uses server-side dry-run on the ConfigMap, Service, Ingress, and Deployment. This exercises API validation and active admission policies without creating test resources.