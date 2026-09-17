# 02 — Edge and trust

This layer turns the private Kubernetes cluster into a named, trusted HTTPS platform. It owns external reachability, DNS, TLS, and secret delivery.

## Name resolution

```text
DNS CONTROL

Kubernetes Ingress / LoadBalancer state
                 │
                 ▼
             ExternalDNS
                 │ signed RFC2136 + TSIG
                 ▼
       BIND9 · 192.168.56.1
       authoritative for lab.test

CLIENT LOOKUP

operator / browser ── DNS query ──► BIND9
operator / browser ◄── A = 192.168.56.200 ── BIND9
```

ExternalDNS is a control-plane component. It creates DNS records; it is not in the application request path.

## HTTPS request path

```text
operator / browser
       │
       │ HTTPS · SNI/Host: app.lab.test
       ▼
┌──────────────────────────────────────────────┐
│ ingress-nginx LoadBalancer Service           │◄──── MetalLB
│ VIP · 192.168.56.200                         │      assigns + L2-advertises VIP
└──────────────────────┬───────────────────────┘      on worker edge network
                       │ Service routing
                       ▼
             ingress-nginx controller Pod
                       │ host/path routing
                       ▼
              sample-java-app Service
                       │
                       ▼
                 application Pod
```

MetalLB owns VIP assignment and L2 advertisement. It is not an HTTP proxy; ingress-nginx terminates TLS and performs application routing.

Only the workers are attached to the host-only edge network. The API server stays on the private cluster network.

## Trust and secret paths

The DNS update key and wildcard TLS certificate both originate from controlled host-side state, then reach only the consumers that need them.

```text
                         local CA
                            │
                 ┌──────────┴──────────┐
                 │                     │
                 ▼                     ▼
        host/browser trust      *.lab.test cert
                                      │
                                      ▼
                             Vault · edge/tls/wildcard
                                      │
                                      ▼
                         Vault Secrets Operator
                                      │
                                      ▼
                      ingress-nginx/lab-wildcard
                                      │
                                      ▼
                         ingress-nginx TLS termination
```

```text
                   Vault · edge/dns/tsig
                      │               │
            ┌─────────┘               └─────────┐
            ▼                                   ▼
   Vault Agent · host                 Vault Secrets Operator
            │                                   │
            ▼                                   ▼
 /run/lab-bind/tsig.key      external-dns/rfc2136-tsig
            │                                   │
            ▼                                   ▼
          BIND9            ◄── signed RFC2136 ── ExternalDNS
```

Secret values do not live in Git. Git contains policies, references, and synchronization objects; Vault contains runtime values.

## DNS

BIND9 is authoritative for `lab.test` on the host. The host resolver routes only that zone to the local BIND instance, so the lab does not replace normal DNS resolution.

ExternalDNS watches Kubernetes ingress/service state and writes records to BIND through RFC2136. The same TSIG value is delivered to BIND through Vault Agent and to ExternalDNS through Vault Secrets Operator.

This removes the manual `/etc/hosts` lifecycle from normal operation. A hostname exists because the corresponding Kubernetes edge object exists.

## TLS

The local CA is installed into the host trust store and browser trust. It signs the wildcard `*.lab.test` certificate. That certificate is stored in Vault, synchronized into `ingress-nginx` by Vault Secrets Operator, and served by ingress-nginx as the platform certificate.

```text
local CA
   │ signs
   ▼
*.lab.test certificate
   │ stored in
   ▼
Vault
   │ VSO sync
   ▼
ingress-nginx/lab-wildcard
   │
   ▼
app.lab.test
jenkins.lab.test
observability.lab.test
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
make edge-up
     │
     ▼
host edge services installed
     │
     ▼
Vault initialized?
   │
   ├── no ──► make vault-init ──► store init output ──► make vault-unseal
   │                                                        │
   │                                                        └──► make edge-up
   │
   └── yes
        │
        ▼
     Vault sealed?
        │
        ├── yes ──► make vault-unseal ──► make edge-up
        │
        └── no ───► continue edge reconciliation
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
