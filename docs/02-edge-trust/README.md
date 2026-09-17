# 02 — Edge and trust

This layer turns the private Kubernetes cluster into a named, trusted HTTPS platform. It owns external reachability, DNS, TLS, and secret delivery.

## Request path

```text
                           operator / browser
                                  │
                                  │ https://*.lab.test
                                  ▼
                    ┌──────────────────────────┐
                   /                          /│
                  / BIND9                   / │
                 └──────────────────────────┘  │
                 │ authoritative zone       │  │
                 │ lab.test          │ /
                 └────────────┬─────────────┘/
                              │ A record
                              ▼
                       192.168.56.200
                              │
                              ▼
                    ┌──────────────────────────┐
                   / MetalLB                  /│
                  / explicit edge VIP       / │
                 └──────────────────────────┘  │
                 │ ingress-nginx Service    │ /
                 └────────────┬─────────────┘/
                              │
                              ▼
                    ingress-nginx · 2 replicas
                              │
                              ▼
                       Kubernetes Service
                              │
                              ▼
                         application Pod
```

Only the workers are attached to the host-only edge network. The API server stays on the private cluster network.

## Trust and secret path

```text
                         operator-held bootstrap material
                                      │
                                      ▼
                              ┌───────────────┐
                             /               /│
                            / Vault         / │
                           └───────────────┘  │
                           │ source of truth │ /
                           └───────┬─────────┘/
                                   │
                    ┌──────────────┼────────────────┐
                    │              │                │
                    ▼              ▼                ▼
              TLS material    DNS TSIG         CI/runtime creds
                    │              │                │
                    │       Vault Agent             │
                    │              │                │
                    │        /run/.../tsig.key      │
                    │              │                │
                    │             BIND9             │
                    │                               │
                    └──── Vault Secrets Operator ───┘
                                   │
                                   ▼
                         Kubernetes Secrets
                                   │
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
               ingress TLS     ExternalDNS      Jenkins / Pods
```

Secret values do not live in Git. Git contains the policy, references, and synchronization objects; Vault contains the values.

## DNS

BIND9 is authoritative for `lab.test` on the host. The host resolver routes only that zone to the local BIND instance, so the lab does not replace normal DNS resolution.

ExternalDNS watches Kubernetes ingress/service state and writes records to BIND through RFC2136. The TSIG key is rendered by Vault Agent on the host and synchronized to the ExternalDNS namespace through a narrowly scoped Vault path.

This removes the manual `/etc/hosts` lifecycle from normal operation. A hostname exists because the corresponding Kubernetes edge object exists.

## TLS

The host CA is trusted locally. Vault stores the wildcard certificate material used for `*.lab.test`. Vault Secrets Operator materializes the certificate into Kubernetes and ingress-nginx serves it as the platform certificate.

```text
local CA trust
     │
     ▼
Vault wildcard certificate
     │
     ▼
VSO → ingress TLS Secret
     │
     ▼
https://app.lab.test
https://jenkins.lab.test
https://observability.lab.test
```

The certificate path is centralized. Individual applications do not each own a separate ad-hoc TLS bootstrap.

## Edge networking

Shared edge values live in [`infra/edge/config.env`](../../infra/edge/config.env):

| Setting | Value |
|---|---|
| host-only CIDR | `192.168.56.0/24` |
| host address | `192.168.56.1` |
| worker addresses | `192.168.56.11`, `192.168.56.12` |
| MetalLB pool | `192.168.56.200-220` |
| ingress VIP | `192.168.56.200` |
| DNS zone | `lab.test` |

MetalLB automatic allocation is disabled for this pool. The ingress controller explicitly owns `192.168.56.200`, so a later LoadBalancer Service cannot silently consume the platform entry address.

## Availability choices

Ingress-nginx runs two replicas across the workers. DNS points to the Service VIP, not to a Pod or worker address. A single ingress Pod can therefore disappear without changing the client-facing address.

The host Vault and BIND services are infrastructure dependencies rather than Kubernetes workloads. This avoids a bootstrap loop where the cluster would need its own DNS/secrets edge before those services could start.

## Vault bootstrap boundary

Vault initialization and unseal are intentionally explicit operator actions.

```text
first start
   │
   ▼
edge host installed
   │
   ▼
Vault uninitialized ──► make vault-init
                              │
                              ▼
                    operator stores init output
                              │
                              ▼
                       make vault-unseal
                              │
                              ▼
                         make edge-up
```

The repository may create policies, AppRoles, Kubernetes synchronization objects, and services. It must not invent or commit the operator's root token, unseal material, registry token, or GitHub token.

## Reconciliation

```bash
make edge-up
make edge-smoke
make edge-validate
```

`edge-up` configures the host edge first, checks Vault state, renders runtime secret material, then reconciles Kubernetes-side edge components. It stops with a concrete instruction when Vault still requires initialization or unseal instead of attempting to bypass that boundary.

## Failure boundaries

A failed DNS update does not require replacing ingress. A failed VSO sync does not require rebuilding Vault. A sealed Vault does not justify manually copying secrets into Kubernetes. Each component has one responsibility and is reconciled at that boundary.

Implementation: [`infra/edge/`](../../infra/edge/), [`platform/edge/`](../../platform/edge/), [`validation/edge/`](../../validation/edge/).
