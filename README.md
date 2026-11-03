# Kubernetes platform lab

This repository builds a three-node Kubernetes cluster on VirtualBox, including a local DNS and TLS edge, Jenkins delivery, metrics, logs, and an admission webhook. It is a local environment for running and testing the release path from a Git commit to a deployed image digest.

## Quick start

Use an Ubuntu x86_64 host with hardware virtualization enabled. The VMs reserve 10 GiB of RAM in total; allow more for the host and build tools. The commands below install packages and change host DNS settings.

```bash
git clone https://github.com/atakang7/k8s-platform-lab.git
cd k8s-platform-lab
make prerequisites
make cluster-up
make cluster-validate
make edge-up
make edge-validate
```

Create local credentials, then load them into Vault. The `.env` file is ignored by Git.

```bash
cp .env.example .env
# Edit .env with your own GitHub, Docker Hub and Cosign credentials.
set -a; source .env; set +a
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_TOKEN="$(jq -r .root_token ~/.local/share/lab-operator/vault-init.json)"
vault kv put secret/ci/github username="$GITHUB_USERNAME" token="$GITHUB_TOKEN"
vault kv put secret/ci/dockerhub username="$DOCKERHUB_USERNAME" token="$DOCKERHUB_TOKEN"
vault kv put secret/ci/cosign private_key="$COSIGN_PRIVATE_KEY" password="$COSIGN_PASSWORD"
vault kv put secret/runtime/dockerhub username="$RUNTIME_DOCKERHUB_USERNAME" token="$RUNTIME_DOCKERHUB_TOKEN"
```

The Cosign private key must match [the public key](delivery/pipeline/resources/lab/delivery/cosign.pub) in the repository. Keep the Vault initialization file off shared storage.

```bash
make jenkins-up
make environment-up
make observability-up
make observability-smoke
make policies-up
make policies-smoke
make e2e-validate
```

The final validation requires the application image in `state/dev.yaml` to have been deployed by Jenkins. On a new registry, configure the Jenkins jobs and allow the initial release to finish first. See [RUNBOOK.md](RUNBOOK.md) for the bring-up sequence and recovery commands.

## Configuration

- [`.env.example`](.env.example): credentials loaded into Vault, never committed.
- [`Vagrantfile`](Vagrantfile): guest image and VM CPU/RAM settings; `MASTER_MEMORY`, `NODE_2_MEMORY` and `WORKER_MEMORY` override the defaults.
- [`infra/edge/config.env`](infra/edge/config.env): lab DNS zone and edge IPs. Network values also appear in the VM and cluster configuration, so change them together.
- [`environments.yaml`](environments.yaml) and [`state/`](state/): deployment environments, namespaces, image digests and promotion state.
- [`infra/edge/versions.env`](infra/edge/versions.env), [`platform/jenkins/versions.env`](platform/jenkins/versions.env) and [`platform/observability/versions.env`](platform/observability/versions.env): component versions.

## How it works

Vagrant creates one control-plane VM (`10.50.0.10`) and two workers (`10.50.0.11`, `10.50.0.12`). Ansible installs Kubernetes. Host-side Vault and BIND9 provide secrets and DNS; MetalLB and ingress-nginx route HTTPS traffic on the `192.168.56.0/24` edge network.

Jenkins builds the Java service, runs checks, publishes and signs a container image, then records its digest in `state/dev.yaml`. The deploy job releases that digest with Helm. Prometheus, Grafana, Fluent Bit and Elasticsearch inspect the result. The Go admission webhook rejects Deployments without CPU and memory requests.

The component guides live in [infra/](infra/README.md), [platform/](platform/README.md), [delivery/](delivery/README.md) and [policies/](policies/README.md).

## Deploy and verify

Open a pull request with a change under `app/`. Jenkins checks the change; after merge, its main-branch job publishes the release and updates the environment state. Stage and prod are promotion targets recorded in Git, not extra clusters created by this checkout.

```bash
make endpoints
make credentials
make e2e-validate
```

To test the source without provisioning the VMs:

```bash
cd app && ./mvnw --batch-mode --no-transfer-progress verify
cd ../policies/resource-requests-webhook && go test ./... && go vet ./...
```

GitHub Actions runs these checks and ShellCheck for each pull request. Full infrastructure validation requires the Ubuntu host and running cluster.

## Limitations

This is a lab, not a high-availability production installation. It has one control plane, fixed private-network defaults and a pinned Ubuntu 20.04 guest image. Elasticsearch is accessible without authentication on the lab edge, and Vault and BIND9 are not continuously monitored. Keep the edge network isolated from untrusted clients; [docs/weaknesses.md](docs/weaknesses.md) records these gaps.

For teardown, run `make destroy` for the VMs and `make edge-down` for host-side edge components. See [RUNBOOK.md](RUNBOOK.md) before removing persistent Vault state.

MIT licensed. See [LICENSE](LICENSE).
