# Application registry bootstrap

`app/k8s/` holds the one-time objects that let the application pull its private image. The runtime itself is the Helm chart in [`../chart/`](../chart/README.md).

```text
registry-secret.yaml ◄── VSO ◄── Vault runtime/dockerhub
```

After Vault and VSO are healthy and `secret/runtime/dockerhub` contains `username` and `token`:

```bash
./app/k8s/bootstrap-registry-auth.sh
```

This creates the application Vault policy/AppRole, Kubernetes `VaultAuth`, and applies the VSO registry Secret declaration.
