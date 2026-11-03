Part of [k8s-platform-lab](../../README.md)

# Environment namespace

The setup script creates the active environment namespace, deploy identities and Vault-backed image pull credentials.

## Run

```sh
make environment-up
```

## Config

| Source | Default | Use |
| --- | --- | --- |
| [../../environments.yaml](../../environments.yaml) | `dev` | Active environment |
| [namespace.yaml](namespace.yaml) | `__NAMESPACE__` | Rendered namespace |
| [registry-pull-read.hcl](registry-pull-read.hcl) | Read-only Vault policy | Registry secret |

## Interfaces

| Path | Purpose |
| --- | --- |
| [bin/up](bin/up) | Host credential check, namespace setup |
| [namespace.yaml](namespace.yaml) | RBAC and namespace manifests |
| `secret/runtime/dockerhub` | Vault source for image pulls |

A cluster accepts one environment at a time.
