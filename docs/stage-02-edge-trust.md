# Stage 2 — Edge, DNS, TLS, and secrets

This stage makes the private cluster reachable from the host without exposing the control plane. It also establishes DNS, TLS, and runtime secret delivery.

## Runtime request path

```text
                            HOST

      ┌──────────────────────────────────────────────┐
     /                                              /│
    /  browser / curl                              / │
   └───────────────┬──────────────────────────────┘  │
                   │ DNS: app.lab.test         │
                   ▼                                  │
        ┌────────────────────┐                        │
        │ BIND9              │  authoritative zone    │
        │ 192.168.56.1       │                        │
        └─────────┬──────────┘                        │
                  │ A = 192.168.56.200                 │
                  ▼                                    │
        ┌────────────────────┐                         │
        │ MetalLB VIP        │                         │
        │ 192.168.56.200     │                         │
        └─────────┬──────────┘                         │
                  │                                    │
                  ▼                                    │
        ┌────────────────────┐                         │
        │ ingress-nginx ×2   │  worker spread          │
        └─────────┬──────────┘                         │
                  │ TLS termination                    │
                  ▼                                    │
        ┌────────────────────┐                         │
        │ Kubernetes Service │                         │
        └─────────┬──────────┘                         │
                  ▼                                    │
               workload
```

The client path does not pass through Vault, VSO, or ExternalDNS. Those components configure the data path; they are control-plane services.

## DNS control flow

```text
Kubernetes Ingress / Service
            │
            │ watched by
            ▼
┌──────────────────────┐
│ ExternalDNS          │
│ cluster              │
└──────────┬───────────┘
           │ RFC2136 + TSIG
           ▼
┌──────────────────────┐
│ BIND9                │
│ host                 │
│ lab.test      │
└──────────┬───────────┘
           │ authoritative A record
           ▼
        host resolver
```

ExternalDNS receives the TSIG credential through VSO. BIND accepts authenticated dynamic updates for the lab zone.

## Secret and TLS control flow

```text
                         host trust boundary

┌──────────────────────┐        ┌──────────────────────┐
│ local CA             │        │ Vault                │
│ trusted by host      │        │ secret authority     │
└──────────┬───────────┘        └──────────┬───────────┘
           │                               │
           │ Vault / wildcard TLS          │ AppRole
           │ trust                         ▼
           │                    ┌──────────────────────┐
           │                    │ Vault Secrets       │
           │                    │ Operator            │
           │                    └──────────┬───────────┘
           │                               │
           │                    ┌──────────┴───────────────┐
           │                    │ Kubernetes Secrets      │
           │                    │ TLS · TSIG · CI creds   │
           │                    │ registry pull auth      │
           │                    └──────────┬───────────────┘
           │                               │
           └───────────────────────────────┼─────────────► consumers
```

Vault is the authority for credential values. Kubernetes Secrets are runtime copies for native consumers. Secret values are not committed.

Vault Agent is used separately for the host BIND process. It authenticates to Vault and renders the DNS TSIG key into a protected runtime file under `/run`; BIND never needs a static committed key.

## Network strategy

`node-2` and `node-3` join `192.168.56.0/24`. `node-1` does not.

MetalLB reserves `192.168.56.200-220`. Automatic allocation is disabled. ingress-nginx explicitly owns `192.168.56.200`, so an unrelated `LoadBalancer` Service cannot silently consume an edge address.

The host uses scoped DNS routing for `lab.test`. Normal host DNS is not replaced.

## First bootstrap

```bash
make edge-up
VAULT_INIT_OUTPUT=/secure/path/vault-init.json make vault-init
make vault-unseal
make edge-up
```

The first `edge-up` installs/configures the host-side dependencies and stops when explicit Vault operator action is required. Vault initialization output must be written outside the repository and protected by the operator.

After Vault is initialized and unsealed, rerun `make edge-up`. The reconciliation creates narrowly scoped identities and applies the Kubernetes edge components.

Normal operation:

```bash
make edge-up
make edge-smoke
make edge-validate
```

After a host reboot, unseal Vault and reconcile the edge again.

## Failure boundaries

The control plane remains private even when the edge is healthy. Losing the ingress VIP affects host traffic but not the Kubernetes API network. Losing Vault prevents secret reconciliation but does not automatically delete already materialized Kubernetes Secrets. Losing BIND prevents name resolution even if ingress remains reachable by IP.

## Source paths

`infra/edge/` owns orchestration and shared addresses. `infra/ansible/roles/{vault,vault_agent,bind9,local_ca,resolver}/` owns host services. `platform/edge/` owns MetalLB, ingress-nginx, ExternalDNS, and VSO. `validation/edge/` owns edge health and integration checks.