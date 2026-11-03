Part of [k8s-platform-lab](../../README.md)

# Kubernetes edge

MetalLB assigns the ingress address, ingress-nginx terminates HTTPS, ExternalDNS updates BIND9, and Vault Secrets Operator syncs credentials.

## Run

```sh
make edge-up
make edge-smoke
make edge-validate
```

## Config

| File | Value | Use |
| --- | --- | --- |
| [metallb/resources/ip-address-pool.yaml](metallb/resources/ip-address-pool.yaml) | `192.168.56.200-220` | LoadBalancer range |
| [ingress-nginx/values.yaml](ingress-nginx/values.yaml) | `nginx` | Ingress class |
| [external-dns/values.yaml](external-dns/values.yaml) | RFC2136 | DNS updates |
| [vault-secrets-operator/](vault-secrets-operator/) | VaultAuth | Secret sync |

## Interfaces

| Path | Purpose |
| --- | --- |
| [health/resources.yaml](health/resources.yaml) | `stage3.lab.test` HTTPS probe |
| [metallb/](metallb/) | VIP allocation |
| [ingress-nginx/](ingress-nginx/) | HTTP ingress |
| [external-dns/](external-dns/) | DNS records |
| [vault-secrets-operator/](vault-secrets-operator/) | Vault integration |
