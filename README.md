# Kubernetes platform lab

A three-node Kubernetes lab on VirtualBox that tests a Jenkins release from source change to digest-pinned deployment.

```text
+--------+  HTTPS  +---------------+  HTTP  +-----------------+
| client | ------> | ingress-nginx | -----> | sample-java-app |
+--------+         +---------------+        +-----------------+
```

BIND9 resolves `*.lab.test` to the MetalLB ingress IP `192.168.56.200`; the control-plane VM is `node-1`, with `node-2` and `node-3` as workers.

```text
+-------------+ source +---------+ image +-------+ scanned OCI +------------+
| GitHub main | -----> | Jenkins | ----> | Trivy | ----------> | Docker Hub |
+-------------+        +---------+       +-------+             +------------+
                                                                  |
                                                                  | digest
                                                                  v
                                                           +----------------+
                                                           | state/dev.yaml |
                                                           +----------------+
                                                                  |
                                                                  | deploy
                                                                  v
                                                              +------+
                                                              | Helm |
                                                              +------+
```

Jenkins builds with BuildKit and signs the published digest with Cosign before recording state.

## Run

Ubuntu x86_64 with virtualization enabled and at least 10 GiB available for the VMs:

```bash
git clone https://github.com/atakang7/k8s-platform-lab.git
cd k8s-platform-lab
make prerequisites
make cluster-up
make cluster-validate
make edge-up
make edge-validate
cp .env.example .env
```

Fill in `.env` using your own credentials; its Cosign key must match [cosign.pub](delivery/pipeline/resources/lab/delivery/cosign.pub).

```bash
set -a; source .env; set +a
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_TOKEN="$(jq -r .root_token ~/.local/share/lab-operator/vault-init.json)"
vault kv put secret/ci/github username="$GITHUB_USERNAME" token="$GITHUB_TOKEN"
vault kv put secret/ci/dockerhub username="$DOCKERHUB_USERNAME" token="$DOCKERHUB_TOKEN"
vault kv put secret/ci/cosign private_key="$COSIGN_PRIVATE_KEY" password="$COSIGN_PASSWORD"
vault kv put secret/runtime/dockerhub username="$RUNTIME_DOCKERHUB_USERNAME" token="$RUNTIME_DOCKERHUB_TOKEN"
make jenkins-up
make environment-up
make observability-up
make observability-smoke
make policies-up
make policies-smoke
make e2e-validate
```

Run the policy and end-to-end checks after Jenkins has deployed the digest recorded in `state/dev.yaml`; see [RUNBOOK.md](RUNBOOK.md) for recovery.

Source-only checks:

```bash
(cd app && ./mvnw --batch-mode --no-transfer-progress verify)
(cd policies/resource-requests-webhook && go test ./... && go vet ./...)
```

## Config

| Var | Default | What |
|---|---|---|
| `IMAGE_NAME` | `ubuntu/focal64` | Vagrant box |
| `IMAGE_VERSION` | `20240821.0.1` | Box version |
| `MASTER_MEMORY` | `2048` | `node-1` RAM, MiB |
| `NODE_2_MEMORY` | `4096` | `node-2` RAM, MiB |
| `WORKER_MEMORY` | `4096` | `node-3` RAM, MiB |
| `MASTER_CPUS` | `2` | `node-1` vCPUs |
| `WORKER_CPUS` | `2` | Each worker's vCPUs |
| `BASE_IP` | `10.50.0` | Cluster node IP prefix |
| `DNS_ZONE` | `lab.test` | Set in [config.env](infra/edge/config.env), not a shell override |
| Credentials | unset | Populate [`.env.example`](.env.example) and load into Vault |

Environment selection and registries: [environments.yaml](environments.yaml); release digests: [state/](state/).

## Limits

- Single control plane; this is not a failover cluster.
- Elasticsearch has no authentication on the lab edge; isolate its network.
- Vault and BIND9 have no continuous alerting; see [known gaps](docs/weaknesses.md).
- This checkout provisions only the configured `dev` cluster; `stage` and `prod` are Git state.
- Host and recovery commands: [RUNBOOK.md](RUNBOOK.md); release rules: [DELIVERY.md](DELIVERY.md); observed failures: [docs/bugs.md](docs/bugs.md).
