# Edge orchestration

`infra/edge/` is the operator entry point for host-side trust,
DNS, TLS, and Kubernetes edge bootstrap.

## 1. What edge-up actually does

~~~text
make edge-up
    │
    ▼
┌──────────────────────┐
│ host foundation      │
│ Vault · CA · prereqs │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ Vault lifecycle      │
│ init / unseal        │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ Vault runtime        │
│ policies · AppRoles  │
│ DNS / TLS secrets    │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ host DNS             │
│ BIND9 · resolver     │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ cluster edge         │
│ VSO · MetalLB        │
│ ingress · ExternalDNS│
└──────────┬───────────┘
           ▼
     edge ready
~~~

That sequence is encoded in [bin/up](bin/up). It is intentionally one
operator path instead of a collection of manual Helm and host commands.

## 2. Host / cluster boundary

~~~text
                 OPERATOR HOST

┌────────────────────┐
│ Vault              │
│ BIND9              │
│ local CA           │
│ system resolver    │
└─────────┬──────────┘
          │ trust + secrets
          ▼

                KUBERNETES

┌────────────────────┐
│ Vault Secrets      │
│ Operator           │
└─────────┬──────────┘
          │
          ├──────────────┐
          │              │
          ▼              ▼
┌──────────────┐  ┌──────────────┐
│ ExternalDNS  │  │ ingress TLS  │
└──────────────┘  └──────────────┘

┌────────────────────┐
│ MetalLB            │
│ ingress-nginx      │
└────────────────────┘
~~~

Host-side trust stays outside Kubernetes. Kubernetes receives only the
runtime material it needs.

## 3. DNS trust path

~~~text
                Vault
                  │
                  ▼
        secret/edge/dns/tsig
                  │
          ┌───────┴────────┐
          │                │
          ▼                ▼
┌─────────────────┐  ┌─────────────────┐
│ Vault Agent     │  │ VSO             │
│ host render     │  │ K8s Secret      │
└────────┬────────┘  └────────┬────────┘
         │                    │
         ▼                    ▼
┌─────────────────┐  ┌─────────────────┐
│ BIND9 TSIG key  │  │ ExternalDNS     │
└────────┬────────┘  └────────┬────────┘
         │                    │
         └─────────┬──────────┘
                   ▼
             signed RFC2136
                   │
                   ▼
                 BIND9
~~~

Both sides use the same Vault-backed key. BIND9 gets the host runtime
file through Vault Agent; ExternalDNS gets the matching Kubernetes
Secret through VSO.

The edge bootstrap waits until Vault Agent has rendered the current key
before continuing.

## 4. DNS control path

~~~text
Service / Ingress
        │
        │ watched by
        ▼
┌────────────────────┐
│ ExternalDNS        │
│ zone filter        │
│ sync policy        │
└─────────┬──────────┘
          │ signed update
          ▼
┌────────────────────┐
│ BIND9              │
│ lab.test           │
│ authoritative only │
└─────────┬──────────┘
          │
          ▼
   DNS A records
~~~

BIND9 is authoritative for the lab zone and does not act as a recursive
resolver for arbitrary client queries.

## 5. TLS path

~~~text
local CA
   │ issues
   ▼
wildcard certificate
   │
   ▼
┌────────────────────┐
│ Vault              │
│ edge/tls/wildcard  │
└─────────┬──────────┘
          ▼
┌────────────────────┐
│ VSO                │
└─────────┬──────────┘
          ▼
┌────────────────────┐
│ Kubernetes TLS     │
│ Secret             │
└─────────┬──────────┘
          ▼
┌────────────────────┐
│ ingress-nginx      │
│ default wildcard   │
└────────────────────┘
~~~

The certificate source stays in Vault. Ingress consumes only the
Kubernetes Secret produced by VSO.

## 6. Traffic path

~~~text
client
  │ DNS lookup
  ▼
┌────────────────────┐
│ BIND9              │
│ returns .200       │
└─────────┬──────────┘
          ▼
┌────────────────────┐
│ MetalLB            │
│ VIP 192.168.56.200 │
└─────────┬──────────┘
          ▼
┌────────────────────┐
│ ingress-nginx      │
│ worker nodes only  │
└─────────┬──────────┘
          ▼
┌────────────────────┐
│ managed Service    │
└────────────────────┘
~~~

MetalLB owns the edge pool and ingress explicitly uses
`192.168.56.200`.

## 7. First bootstrap vs normal run

~~~text
FIRST RUN

make edge-up
    │
    ├── initialize Vault
    ├── retain operator state
    ├── unseal Vault
    └── reconcile everything


LATER RUN

make edge-up
    │
    ├── read operator state
    ├── unseal if needed
    └── reconcile everything
~~~

Vault init and unseal material is written outside Git to the mode-0600
operator-state file configured by `VAULT_INIT_OUTPUT`.

After a host reboot, use the same command:

~~~bash
make edge-up
~~~

No second bootstrap procedure is required.

## 8. Validation path

~~~text
make edge-smoke
      │
      ▼
quick edge health


make edge-validate
      │
      ▼
┌──────────────────────┐
│ API not edge-exposed │
├──────────────────────┤
│ Vault unsealed       │
├──────────────────────┤
│ BIND authoritative   │
├──────────────────────┤
│ unsigned DNS denied  │
├──────────────────────┤
│ Secrets from Vault   │
├──────────────────────┤
│ HTTPS ingress        │
└──────────────────────┘
~~~

Use the smoke check during normal iteration. Use the deep validation
when proving the complete edge contract.

## 9. Main files

| Path | Responsibility |
|---|---|
| `bin/up` | complete edge reconciliation order |
| `bin/down` | remove edge releases, retain Vault data |
| `bin/vault-init` | initialize local Vault when needed |
| `bin/vault-unseal` | unseal from operator-held state |
| `config.env` | shared addresses and zone values |
| `versions.env` | pinned edge component versions |
| `lib/vault.sh` | policies, identities, runtime secrets |
| `lib/kubernetes.sh` | Kubernetes edge reconciliation |
| `lib/with-kubeconfig.sh` | scoped cluster access helper |

Kubernetes-resident component details continue in
**[platform/edge/README.md](../../platform/edge/README.md)**.
