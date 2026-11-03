# Kubernetes edge

`platform/edge/` owns the cluster-side components that turn host DNS
and the worker edge network into managed HTTPS ingress.

## 1. Edge map

~~~text
                    CONTROL PATH

Service / Ingress
       │
       ▼
┌──────────────────┐
│ ExternalDNS      │
│ RFC2136 + TSIG   │
└────────┬─────────┘
         ▼
┌──────────────────┐
│ host BIND9       │
│ lab.test         │
└──────────────────┘


                    TRAFFIC PATH

client
  │
  ▼
BIND9
  │ returns VIP
  ▼
┌──────────────────┐
│ MetalLB          │
│ 192.168.56.200   │
└────────┬─────────┘
         ▼
┌──────────────────┐
│ ingress-nginx    │
│ 2 replicas       │
└────────┬─────────┘
         ▼
managed Services
~~~

DNS control and user traffic are separate flows. ExternalDNS manages
records; it never sits in the request path.

## 2. Secret delivery

~~~text
                 HOST VAULT
                     │
          ┌──────────┴──────────┐
          │                     │
          ▼                     ▼
  DNS TSIG material      wildcard TLS
          │                     │
          └──────────┬──────────┘
                     ▼
            ┌──────────────────┐
            │ Vault Secrets    │
            │ Operator         │
            └────────┬─────────┘
                     │
          ┌──────────┴──────────┐
          │                     │
          ▼                     ▼
┌──────────────────┐   ┌──────────────────┐
│ ExternalDNS      │   │ ingress-nginx    │
│ TSIG Secret      │   │ TLS Secret       │
└──────────────────┘   └──────────────────┘
~~~

Vault remains the source of truth. Kubernetes receives runtime Secrets
through VSO.

## 3. MetalLB

~~~text
worker edge NICs
192.168.56.11 / .12
        │
        ▼
┌──────────────────────┐
│ MetalLB L2 mode      │
│ pool .200 - .220     │
│ autoAssign: false    │
└──────────┬───────────┘
           │ explicit VIP
           ▼
┌──────────────────────┐
│ ingress Service      │
│ 192.168.56.200       │
└──────────────────────┘
~~~

The edge pool is reserved, but addresses are not handed out
automatically. ingress-nginx explicitly requests `192.168.56.200`.

## 4. Ingress

~~~text
192.168.56.200
      │
      ▼
┌────────────────────┐
│ ingress-nginx      │
│ LoadBalancer      │
└─────────┬──────────┘
          │
   ┌──────┴──────┐
   │             │
   ▼             ▼
node-2         node-3
controller    controller
   │             │
   └──────┬──────┘
          ▼
host/path routing
          │
          ▼
Kubernetes Service
~~~

The controllers run on the worker edge nodes. The control plane has no
edge NIC and does not carry host-facing traffic.

## 5. ExternalDNS

~~~text
Kubernetes API
      │
      │ watches
      ▼
Service + Ingress
      │
      ▼
┌────────────────────┐
│ ExternalDNS        │
│ domain filter      │
│ sync policy        │
│ TXT ownership      │
└─────────┬──────────┘
          │ signed RFC2136
          ▼
┌────────────────────┐
│ host BIND9         │
└─────────┬──────────┘
          ▼
lab.test
~~~

ExternalDNS reconciles records from Kubernetes metadata into the
authoritative lab zone.

## 6. End-to-end request

~~~text
https://app.lab.test
             │
             ▼
      DNS lookup
             │
             ▼
          BIND9
             │
             ▼
       192.168.56.200
             │
             ▼
          MetalLB
             │
             ▼
       ingress-nginx
             │
             ▼
      application Service
             │
             ▼
             Pod
~~~

TLS terminates at ingress-nginx using the wildcard certificate delivered
from Vault.

## 7. Component ownership

| Path | Responsibility |
|---|---|
| `metallb/` | explicit VIP pool and L2 advertisement |
| `ingress-nginx/` | host-facing ingress controllers |
| `external-dns/` | DNS reconciliation for `lab.test` |
| `vault-secrets-operator/` | Vault-to-Kubernetes Secret delivery |
| `health/` | retained DNS/TLS/ingress health endpoint |

## 8. Reconcile

Do not manage these components independently during normal operation.

~~~text
make edge-up
    │
    ▼
host trust + DNS
    │
    ▼
VSO
    │
    ▼
MetalLB
    │
    ▼
ingress-nginx
    │
    ▼
ExternalDNS
    │
    ▼
edge health
~~~

Quick check:

~~~bash
make edge-smoke
~~~

Full integration check:

~~~bash
make edge-validate
~~~

Values and manifests here are desired state. Manual Helm changes are
temporary diagnostics only.

The owning orchestration flow is documented in
**[infra/edge/README.md](../../infra/edge/README.md)**.
