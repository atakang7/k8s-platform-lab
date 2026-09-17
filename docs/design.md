# Design choices

## Stage 5 observability

| Choice | Why | Tradeoff |
|---|---|---|
| Pinned kube-prometheus-stack and Fluent Bit charts, official Elasticsearch image | Keeps metrics CRDs and log shipping while avoiding a second operator | Elasticsearch is a manually managed single node |
| One ingress hostname with subpaths | Reuses ExternalDNS, ingress-nginx, and wildcard TLS | Elasticsearch needs a separate rewrite rule |
| Single Elasticsearch node on node-2 | Keeps the control plane free for Kubernetes | No failover |
| Elasticsearch without internal authentication | Keeps the lab resource footprint small | Access depends on the host-only edge boundary |
| local-path PVCs for Prometheus and Elasticsearch | Preserves state across pod recreation | Node loss loses access to local data |
| AlertManager with an internal receiver | Demonstrates the restart alert route | No external notification delivery |

## Jenkins platform

| Choice | Why | Tradeoff |
|---|---|---|
| Controller pinned to node-3 | Case requirement | Availability depends on node-3 |
| Existing ingress-nginx LoadBalancer | One edge, DNS, and TLS path | Ingress is a shared dependency |
| local-path PVC | Existing storage fits the three-VM lab; home survives pod recreation and upgrades | Node-3 loss is not covered by HA storage |

## Edge, DNS, and secrets

| Choice | Why | Tradeoff |
|---|---|---|
| Worker-only host-only NICs | The API and etcd stay on the private network | Edge traffic depends on two workers |
| MetalLB Layer 2 pool with `autoAssign: false` | A new LoadBalancer Service cannot take an edge VIP accidentally | Exposure needs explicit pool and IP annotations |
| Two ingress replicas with hostname spread | Either worker can fail while an ingress Pod remains | Small extra CPU and memory cost |
| Host BIND9 with TSIG and typed update policy | ExternalDNS proves automatic Service and Ingress records | One DNS server in this lab |
| Host Vault with Raft and TLS | Runtime secrets have an authority outside workload lifecycle | One host Vault is not highly available |
| AppRole for Vault Agent and VSO | Vault need not reach the private Kubernetes API | Bootstrap SecretIDs must be protected and rotated by an operator |
| VSO runtime Kubernetes Secrets | Consumers use native Secret interfaces while Vault owns values | Runtime copies exist in etcd and namespaces need strict access |
| mkcert local CA | Host can verify Vault and wildcard HTTPS | CA trust is limited to this lab |

The host Vault CA key and initial unseal/root material are operator root-of-trust items. The CA key stays under `/etc/lab-ca` with mode `0600`; init output must be placed outside the repository. Vault Agent's BIND key file lives under `/run`. VSO AppRole bootstrap credentials are Kubernetes Secrets, while the DNS and TLS values themselves remain authored in Vault.

The lab uses one Vault, one BIND, a host-only LAN, local PKI, and Layer 2 VIPs. A production design would use HA/external secret management, redundant authoritative DNS, real routed networking, trusted PKI, and an HA cloud load balancer or BGP design. This lab demonstrates the trust boundaries without claiming global HA.

## Cluster foundation

| Choice | Why | Tradeoff |
|---|---|---|
| One control plane, two workers | Matches the requested local topology | API server is not highly available |
| VirtualBox internal network | Keeps the required VM CIDR without changing host network policy | Host cannot directly route to VM addresses |
| Adaptive VM memory and ENV overrides | Supports hosts with different memory budgets | Small tiers have little spare capacity; unsafe overrides are operator-owned |
| `containerd` with systemd cgroups | Uses a small Kubernetes runtime setup | Follows the Ubuntu package lifecycle |
| `kubeadm` | Uses standard bootstrap mechanics | Control-plane HA needs more nodes |
| Pinned Kubernetes package version | Makes package and API behavior repeatable | Upgrades need an intentional variable change |
| Pinned Calico manifest | Keeps CNI and Pod CIDR explicit | Ansible manages its lifecycle |
| local-path provisioner | Gives the lab dynamic PVCs with little overhead | Volumes are node-local |

The VM, Pod, and Service ranges in [architecture](architecture.md) do not overlap. Ansible roles are narrow and can run again without reinitializing joined nodes. Cluster validation checks node health, cross-node Pod traffic, and a dynamically provisioned PVC.

## Resource sizing

Vagrant uses available host memory for a new lab. Once project VMs exist, their configured memory becomes the default for later commands. Starting VMs without overrides requires at least 6 GB available. Cleanup and read-only commands work below that threshold.

| Available host RAM | Control plane | Worker baseline |
|---:|---:|---:|
| 20 GB or more | 4096 MB | 3072 MB |
| 12–20 GB | 3072 MB | 2560 MB |
| 8–12 GB | 2560 MB | 2048 MB |
| 6–8 GB | 2048 MB | 1536 MB |

`node-2` defaults to 2048 MB for Stage 5; `node-3` uses the worker baseline. The target lab uses 1792 MB on node-1 and 2048 MB on each worker. `MASTER_MEMORY`, `WORKER_MEMORY`, and `NODE_2_MEMORY` override these defaults.

## Container

The supplied application source is preserved from `https://github.com/SampleJavaApp/app` at commit `dc11042a28e30a85fc986878a83d7d7cefc30493`.

| Choice | Why | Tradeoff |
|---|---|---|
| Supplied Maven Wrapper | Reuses the application's build tool | Wrapper remains part of the build context |
| Pinned Eclipse Temurin Java 11 builder and runtime digests | Makes base images explicit | Tag and digest need a reviewed update together |
| Separate build and runtime stages | Runtime contains only the JAR | Two Docker build stages |
| Fixed UID/GID `10001` | Runs without root | Application must work with that identity |
| Git SHA image tag and OCI labels | Links image to source | Needs source metadata in unpacked copies |
| Registry digest after push | Identifies the immutable artifact | Requires registry access |

`.dockerignore` allowlists wrapper files, `pom.xml`, and source. The runtime contains neither Maven nor the JDK compiler. The image uses an exec-form `java -jar /app/application.jar` entrypoint. No `latest` tag is created.
