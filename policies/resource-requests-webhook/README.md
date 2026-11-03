Part of [k8s-platform-lab](../../README.md)

# Resource requests webhook

A Go HTTP server that checks Deployment admission requests for nonzero CPU and memory requests on regular and init containers.

## Run

```sh
cd policies/resource-requests-webhook
go test ./...
go run ./cmd/webhook -tls-cert /path/tls.crt -tls-key /path/tls.key
```

## Config

| Flag | Default | Use |
| --- | --- | --- |
| `-port` | `8443` | HTTPS listener |
| `-tls-cert` | `/etc/webhook/certs/tls.crt` | Serving certificate |
| `-tls-key` | `/etc/webhook/certs/tls.key` | Private key |

## Interfaces

| Path | Method | Purpose |
| --- | --- | --- |
| `/validate` | POST | AdmissionReview v1 |
| `/healthz` | GET, HEAD | Probe |
| [cmd/webhook/main.go](cmd/webhook/main.go) | | Request handler |
| [helm/resource-requests-webhook/](helm/resource-requests-webhook/README.md) | | Kubernetes resources |

The request body limit is 1 MiB. HTTP read and write deadlines are 10 seconds.
