Part of [k8s-platform-lab](../../README.md)

# Edge bootstrap

The host runs Vault, BIND9 and the local CA; worker-facing controllers run inside Kubernetes.

## Run

```sh
make edge-up
make edge-smoke
```

Use `make edge-validate` for the DNS, TLS and network boundary checks. `make edge-down` removes the edge components.

## Config

| Variable | Default | Use |
| --- | --- | --- |
| `DNS_ZONE` | `lab.test` | Local DNS zone |
| `EDGE_HOST_IP` | `192.168.56.1` | DNS and Vault host |
| `INGRESS_VIP` | `192.168.56.200` | MetalLB ingress address |
| `OPERATOR_STATE_DIRECTORY` | `~/.local/share/lab-operator` | Local private state |

Defaults are set in [config.env](config.env); tool pins are in [versions.env](versions.env).

## Interfaces

| Path | Purpose |
| --- | --- |
| [bin/up](bin/up) | Host and cluster reconciliation |
| [bin/vault-init](bin/vault-init) | Initial Vault state |
| [bin/vault-unseal](bin/vault-unseal) | Unseal Vault |
| [lib/with-kubeconfig.sh](lib/with-kubeconfig.sh) | Cluster API tunnel |

The Vault initialization output is stored outside Git.
