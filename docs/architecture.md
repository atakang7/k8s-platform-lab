# Architecture

## Stage 3 edge

```text
                       Host
              Vault 2.0.4      BIND9
                 │               ▲ TSIG/RFC2136
                 │ VSO        ExternalDNS
═════════════════╪════ host-only 192.168.56.0/24 ════════
                 │      VIP 192.168.56.200
                 │               │ MetalLB Layer 2
                 └──────────► ingress-nginx (2 replicas)
                                 │
══════════════════ private 10.50.0.0/24 ══════════════════
              node-1 API         │ Services → Pods
              (no edge NIC)     node-2 / node-3
```

Vault and BIND bind to loopback and the host edge address only. Vault Agent reads the DNS key into a protected runtime file for BIND; VSO authenticates with separate AppRoles and creates the ExternalDNS TSIG and ingress TLS Kubernetes Secrets. Host requests for `lab.test` go to BIND through scoped systemd-resolved routing. Deep edge validation retains a small test backend for subsequent smoke tests.

## Stage 4 Jenkins

```text
jenkins.lab.test → ingress-nginx LoadBalancer (192.168.56.200)
                       → Jenkins ClusterIP → controller on node-3 → local-path PVC
```

ExternalDNS creates the hostname from the Ingress. The ingress controller serves its VSO-managed wildcard TLS certificate. VSO also delivers Jenkins admin credentials from Vault; JCasC defines Jenkins configuration.

## Stage 5 observability

```text
Kubernetes metrics → Prometheus → Grafana dashboard
Pod restart → PrometheusRule → AlertManager
Kubernetes container logs → Fluent Bit → Elasticsearch

observability.lab.test → existing ingress-nginx / wildcard TLS
                              ├─ /grafana
                              ├─ /prometheus
                              └─ /elasticsearch
```

ExternalDNS creates the single hostname. Prometheus and Elasticsearch use local-path PVCs. The Git-managed dashboard is provisioned through a labeled ConfigMap. Application file logging remains a later stage.

## Running foundation

```text
Host
  Vagrant / VirtualBox
       ↓
  node-1 (control plane) ── node-2 (worker)
       │                    node-3 (worker)
       ↓
  Ansible → containerd + kubeadm
       ↓
  Calico networking + local-path storage
       ↓
  validation/cluster
```

| Node | Role | VM address |
|---|---|---|
| `node-1` | Control plane | `10.50.0.10` |
| `node-2` | Worker | `10.50.0.11` |
| `node-3` | Worker | `10.50.0.12` |

Only workers have edge NICs: `node-2` → `192.168.56.11`, `node-3` → `192.168.56.12`. The host is `192.168.56.1`; MetalLB reserves `.200–.220` with automatic allocation disabled.

| Network | CIDR | Owner |
|---|---|---|
| VM | `10.50.0.0/24` | Vagrant |
| Pod | `10.244.0.0/16` | kubeadm and Calico |
| Service | `10.96.0.0/12` | Kubernetes |
| Edge | `192.168.56.0/24` | VirtualBox host-only + MetalLB |

The VM range is a VirtualBox internal network. Vagrant reaches guests through managed NAT SSH forwards; Calico uses VM addresses rather than NAT addresses.

## Application artifact

```text
Supplied Java source
       ↓
Maven Wrapper build and tests
       ↓
Java 11 JAR
       ↓
non-root Java 11 runtime image
       ↓
Git SHA tag → registry digest when pushed
```

The application listens on port `9001`. `GET /api/foos?val=...` returns and logs the supplied value. This repository does not yet deploy the application to Kubernetes.

## Ownership boundaries

| Area | Owns |
|---|---|
| Vagrant | VM creation, networking, CPU, RAM |
| `infra/ansible/` | OS setup, container runtime, Kubernetes, CNI, storage |
| `app/` | Source, image build, future app-specific manifests |
| `infra/ansible/roles/` | Host BIND, Vault, Vault Agent, local CA, and resolver |
| `infra/edge/` | Edge lifecycle orchestration and shared configuration |
| `platform/edge/` | MetalLB, ingress-nginx, ExternalDNS, VSO |
| `delivery/` | Future delivery automation |
| `policies/` | Future admission and security policy |
| `validation/` | Outcome checks by capability |
