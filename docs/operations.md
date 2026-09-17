# Operations

Run commands from the repository root.

## Required Secrets

Store values in Vault outside Git. The VSO definitions in `app/k8s/registry-secret.yaml` and `platform/jenkins/resources/ci-secrets.yaml` declare these inputs and their Kubernetes Secret destinations.

| Vault path | Fields | Consumer | Purpose |
|---|---|---|---|
| `secret/runtime/dockerhub` | `username`, `token` | Application runtime | DockerHub authentication for private image pulls |
| `secret/ci/dockerhub` | `username`, `token` | Jenkins | DockerHub authentication for CI/CD |
| `secret/ci/github` | `username`, `token` | Jenkins | Private GitHub SCM polling and checkout |

## Stage 5 observability

Run `make observability-up` after Stage 3 is healthy, then `make observability-smoke`. The endpoints are `https://observability.lab.test/grafana/`, `/prometheus/`, and `/elasticsearch/`. Grafana's generated admin password is in the `observability-grafana` Kubernetes Secret. The smoke check verifies trusted HTTPS and a Fluent Bit index. Elasticsearch runs without authentication on the host-only lab network.

The deployment requires each worker to have at least 1,450,000 Ki allocatable memory. The initial 1 GB / 1.5 GB worker configuration was below that floor and drove both workers NotReady. The lab now targets 2048 MB per worker and 1792 MB on the control plane; the install command checks worker capacity before creating resources.

The single-node Elasticsearch pod runs on node-2 with Prometheus; Grafana, the Prometheus operator, and AlertManager run on node-3. Prometheus retains one day on a 2 GiB local-path PVC; Elasticsearch has a 4 GiB local-path PVC. Neither volume is highly available. AlertManager keeps restart alerts in its UI without an external notification receiver.

## Stage 4 Jenkins

Run `make jenkins-up` after Stage 3 is healthy and Vault is unsealed. It uses the existing Vault bootstrap token at a hidden prompt, creates a narrow Jenkins VSO identity and Vault-held admin password, then installs the pinned official chart. Jenkins is at `https://jenkins.lab.test`; its admin password remains in Vault. The controller has no executors, and its home is on a node-3 local-path PVC.

## Stage 3 edge lifecycle

The host runs Vault, Vault Agent, BIND, the local CA, and scoped DNS resolution. Ansible owns their configuration in `infra/ansible/playbooks/edge-host.yml`; `infra/edge/bin/up` coordinates Vault bootstrap and the declarative Kubernetes resources in `platform/edge/`. The root Makefile delegates each operator action.

| Action | Command | Why / tradeoff |
|---|---|---|
| Start the private cluster | `vagrant up` | The edge depends on three running nodes. Node-1 has no edge NIC. |
| Configure the edge | `make edge-up` | Reconciles host and platform state; stops for explicit Vault initialization or unseal. |
| Initialize Vault once | `VAULT_INIT_OUTPUT=/protected/absolute/path make vault-init` | Writes the unseal key and root token to a new `0600` operator file outside the repository. Move it to protected storage. |
| Unseal Vault | `make vault-unseal` | Enter an operator-held key after initialization or host reboot. |
| Check normal health | `make edge-smoke` | Checks nodes, host services, workloads, DNS, and trusted HTTPS quickly. |
| Run full validation | `make edge-validate` | Exercises security boundaries and DNS creation/deletion; retains the HTTPS test backend for smoke tests. |
| Stop the edge | `make edge-down` | Removes edge releases and scoped resolution, while retaining Vault Raft data and the dynamic BIND zone. |

First use: run `vagrant up`, `make edge-up`, `make vault-init`, `make vault-unseal`, then `make edge-up` again. The second `edge-up` prompts for the root token only when AppRole bootstrap is missing. It creates narrow DNS and TLS identities, then Vault Agent and VSO deliver the relevant secrets. Do not put the token in shell history. Subsequent runs reuse the CA, TLS certificate, TSIG, SecretIDs, Vault storage, BIND zone, and Helm releases.

The host-only network is `192.168.56.0/24` on `vboxnet0`, with the host at `192.168.56.1/24`. The Vagrantfile checks subnet and DHCP conflicts. This lab uses static edge addresses; disable DHCP on the dedicated interface with `VBoxManage dhcpserver modify --network=HostInterfaceNetworking-vboxnet0 --disable` before bringing up the workers. The public CA is installed through the standard host system trust store at `/usr/local/share/ca-certificates/lab.crt`; keep `/etc/lab-ca/rootCA-key.pem` private.

Architecture values are in `infra/edge/config.env`; pinned versions are in `infra/edge/versions.env`. Kubernetes values and resources remain declarative in `platform/edge/`. The host reaches the private Kubernetes API through a short-lived SSH tunnel. For diagnosis, use `systemctl status vault vault-agent named`, `vault status`, `dig @192.168.56.1 edge.lab.test A`, and `resolvectl query edge.lab.test`. `edge.lab.test` points to the ingress VIP; HTTP 404 is expected without a matching Ingress rule. After a reboot, unseal Vault and rerun `make edge-up`.

## Cluster lifecycle

| Action | Command |
|---|---|
| Start and provision | `vagrant up` or `make cluster-up` |
| Validate outcomes | `make cluster-validate` |
| Reapply configuration | `vagrant provision node-3` |
| Inspect nodes | `vagrant ssh node-1 -c 'kubectl get nodes -o wide'` |
| Destroy lab | `make destroy` |

Vagrant provisions the cluster once, from `node-3`, using `infra/ansible/site.yml`. Cluster validation runs `infra/ansible/validate.yml` against Vagrant's generated inventory. Run `vagrant up` first so the inventory exists.

For a memory-constrained host:

```bash
MASTER_MEMORY=2048 NODE_2_MEMORY=1024 WORKER_MEMORY=1536 vagrant up
```

## Container validation

```bash
make container-validate
```

The validator uses the current Git commit and `origin` URL for the image tag and OCI labels. For an unpacked working copy without Git metadata, provide both values:

```bash
STAGE2_GIT_SHA=dc11042a28e30a85fc986878a83d7d7cefc30493 \
STAGE2_SOURCE_REPOSITORY='https://github.com/<owner>/<submission-repository>' \
  make container-validate
```

The validator builds and tests with the Maven Wrapper, builds the runtime image, starts it on an ephemeral localhost port, checks the HTTP response and log output, verifies the non-root UID and OCI labels, and checks that build tools and source are absent. It reports `PASS`, `FAIL`, or `SKIP`.

## Optional private Docker Hub push

Create a private repository. Supply an access token through local secure tooling, then use Docker's standard-input login:

```bash
export DOCKERHUB_USERNAME='<docker-hub-user>'
export DOCKERHUB_TOKEN='<docker-hub-access-token>'
printf '%s' "${DOCKERHUB_TOKEN}" |
  docker login --username "${DOCKERHUB_USERNAME}" --password-stdin
```

```bash
DOCKERHUB_REPOSITORY='<docker-hub-user>/<private-repository>' \
STAGE2_PUSH=true \
  make container-validate
```

The script reports `user/repository@sha256:<digest>` after the push. Keep the digest for later deployment work.
