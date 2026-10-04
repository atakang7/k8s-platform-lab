# Infrastructure

`infra/` owns the machines, Kubernetes foundation, and host-side edge
services. Kubernetes-resident edge components live under
[platform/edge/](../platform/edge/README.md).

## 1. Infrastructure boundary

~~~text
                    OPERATOR HOST

             ┌──────────────────────┐
             │ Vagrant             │
             │ VirtualBox          │
             │ Ansible             │
             └──────────┬───────────┘
                        │ creates VMs
                        ▼
             ┌──────────────────────┐
             │ 3-node VM cluster    │
             │ 10.50.0.0/24        │
             └──────────┬───────────┘
                        │ provisions
                        ▼
             ┌──────────────────────┐
             │ infra/ansible       │
             │ OS + Kubernetes     │
             └──────────┬───────────┘
                        ▼
             ┌──────────────────────┐
             │ running Kubernetes  │
             └──────────────────────┘


                    HOST EDGE

             ┌──────────────────────┐
             │ infra/edge          │
             └──────────┬───────────┘
                        │
          ┌─────────────┴──────────────┐
          │                            │
          ▼                            ▼
┌────────────────────┐      ┌────────────────────┐
│ host services      │      │ platform/edge     │
│ Vault · BIND9 · CA │      │ MetalLB · ingress │
│ resolver           │      │ ExternalDNS · VSO │
└────────────────────┘      └────────────────────┘
~~~

Infrastructure stops at the cluster and host-edge boundary. Application
delivery, Jenkins, and observability are owned by higher-level directories.

## 2. VM topology

~~~text
                  Kubernetes private network
                       10.50.0.0/24

                ┌────────────────────┐
                │ node-1             │
                │ CONTROL PLANE      │
                │ 10.50.0.10         │
                │ 2 CPU · 2 GiB      │
                │ API · etcd         │
                │ scheduler          │
                └─────────┬──────────┘
                          │
             ┌────────────┴────────────┐
             │                         │
             ▼                         ▼
   ┌────────────────────┐    ┌────────────────────┐
   │ node-2             │    │ node-3             │
   │ WORKER             │    │ WORKER             │
   │ 10.50.0.11         │    │ 10.50.0.12         │
   │ 2 CPU · 4 GiB      │    │ 2 CPU · 4 GiB      │
   │ edge 192.168.56.11 │    │ edge 192.168.56.12 │
   └─────────┬──────────┘    └─────────┬──────────┘
             │                         │
             └────────────┬────────────┘
                          ▼
                 host-only edge network
                    192.168.56.0/24
                          │
                          ▼
                 MetalLB VIP range
             192.168.56.200 - .220
~~~

The control plane has no edge NIC. Only workers participate in the
host-accessible edge network.

~~~text
VM network       10.50.0.0/24
Pod CIDR         10.60.0.0/16
Service CIDR     10.70.0.0/16
edge network     192.168.56.0/24
MetalLB pool     192.168.56.200 - 192.168.56.220
~~~

**Source:** [Vagrantfile](../Vagrantfile)

## 3. Provisioning flow

~~~text
vagrant up
    │
    ▼
┌──────────────────────┐
│ create node-1        │
│ create node-2        │
│ create node-3        │
└──────────┬───────────┘
           │ all VMs exist
           ▼
┌──────────────────────┐
│ node-3 provisioner   │
│ Ansible site.yml     │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ common OS state      │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ containerd           │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ Kubernetes packages  │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ kubeadm control      │
│ plane on node-1      │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ join node-2/node-3   │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ Calico networking    │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ local-path storage   │
└──────────┬───────────┘
           ▼
   cluster ready
~~~

A single host-side Vagrant Ansible provisioner is attached to the
`node-3` machine definition so the cluster-wide play runs only after all
three VMs exist.

Create and validate:

~~~bash
make cluster-up
make cluster-validate
~~~

Reconcile an existing cluster:

~~~bash
vagrant provision node-3
~~~

Permanent fixes belong in the owning Ansible role. SSH-only fixes are for
diagnosis, not desired state.

**Source:** [Ansible foundation](ansible/README.md)

## 4. Reconcile vs rebuild

~~~text
normal config change
        │
        ▼
┌──────────────────────┐
│ rerun Ansible        │
│ reconcile in place   │
└──────────────────────┘


bootstrap identity change
        │
        ▼
┌──────────────────────┐
│ cluster rebuild      │
└──────────────────────┘
~~~

Normal role changes are idempotent and should converge an existing cluster.

Changes to one-time cluster identity are different. Examples include the
Pod CIDR, Service CIDR, control-plane endpoint, or VM topology. Those are
rebuild operations rather than silent in-place mutations.

## 5. Host-edge trust path

~~~text
                 ┌──────────────────┐
                 │ Vault on host    │
                 └────────┬─────────┘
                          │
             ┌────────────┴────────────┐
             │                         │
             ▼                         ▼
   ┌──────────────────┐      ┌──────────────────┐
   │ edge/dns/tsig    │      │ edge/tls/...    │
   └────────┬─────────┘      └────────┬─────────┘
            │                         │
      ┌─────┴──────┐                  ▼
      │            │          ┌──────────────────┐
      ▼            ▼          │ VSO              │
┌──────────┐  ┌──────────┐    │ ingress TLS     │
│Vault     │  │ VSO      │    │ Secret          │
│Agent     │  │          │    └──────────────────┘
└────┬─────┘  └────┬─────┘
     │              │
     ▼              ▼
┌──────────┐  ┌──────────────┐
│BIND9 TSIG│  │ExternalDNS   │
│runtime   │  │TSIG Secret   │
└────┬─────┘  └────┬─────────┘
     │              │
     └──────┬───────┘
            ▼
      signed RFC2136
            │
            ▼
          BIND9
~~~

The same Vault-held DNS secret is delivered to both sides of the update
path: BIND9 receives its runtime TSIG key through Vault Agent, while
ExternalDNS receives the matching Kubernetes Secret through VSO.

TLS follows the same principle: Vault is the source, VSO delivers the
runtime Kubernetes Secret.

**Source:** [edge orchestration](edge/README.md)

## 6. Edge traffic handoff

~~~text
ExternalDNS
    │ writes DNS
    ▼
BIND9
    │ returns VIP
    ▼
client
    │
    ▼
┌──────────────────────┐
│ MetalLB              │
│ 192.168.56.200       │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│ ingress-nginx        │
│ worker edge NICs     │
└──────────┬───────────┘
           ▼
   Kubernetes Service
~~~

MetalLB automatic allocation is disabled for the edge pool. The ingress
Service explicitly owns `192.168.56.200`.

The Vagrant preflight also rejects:
- host address or route conflicts with `192.168.56.0/24`;
- VirtualBox DHCP overlap with the reserved MetalLB range.

## 7. Operator-held state

~~~text
                    OUTSIDE GIT

          ┌────────────────────────┐
          │ Vault init output      │
          │ unseal material        │
          │ Vault root token       │
          │ CA private key         │
          │ AppRole SecretIDs      │
          │ GitHub / registry creds│
          └────────────────────────┘
~~~

These values are operator-held runtime state. They are deliberately not
stored in the repository.

## 8. Main paths

| Path | Responsibility |
|---|---|
| `bin/prerequisites` | install operator-host tools |
| `ansible/site.yml` | cluster provisioning entry point |
| `ansible/group_vars/all.yml` | versions, CIDRs, topology pins |
| `ansible/roles/` | OS, runtime, Kubernetes, network, storage |
| `ansible/playbooks/edge-host.yml` | host edge reconciliation |
| `edge/bin/up` | end-to-end edge reconciliation |
| `edge/bin/down` | remove edge releases, keep Vault data |
| `edge/bin/vault-init` | one-time Vault initialization |
| `edge/bin/vault-unseal` | operator unseal action |
| `edge/lib/` | Vault, Kubernetes tunnel, and VSO helpers |

For Kubernetes provisioning details, continue with
**[infra/ansible/README.md](ansible/README.md)**.

For DNS, Vault, TLS, and edge bootstrap details, continue with
**[infra/edge/README.md](edge/README.md)**.
