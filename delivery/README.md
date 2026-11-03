Part of [k8s-platform-lab](../README.md)

# Delivery

Jenkins builds and signs service images, records image digests in Git, and deploys releases from environment state.

## Run

Jenkins reads the checked-in [pipeline definitions](pipeline/README.md). The operator prepares it with:

```sh
make jenkins-up
make environment-up
```

## Config

| Source | Default | Use |
| --- | --- | --- |
| [../environments.yaml](../environments.yaml) | `dev` | Cluster environment |
| [../state/](../state/) | `dev`, `stage`, `prod` | Desired release identity |
| [../app/chart/Chart.yaml](../app/chart/Chart.yaml) | Chart version | Service release version |

## Interfaces

| Path | Purpose |
| --- | --- |
| [Jenkinsfile.platform](Jenkinsfile.platform) | Platform checks and chart publication |
| [Jenkinsfile.deploy](Jenkinsfile.deploy) | Git state verification and deployment |
| [pipeline/](pipeline/README.md) | Shared Groovy stages and shell scripts |
| [jenkins/](jenkins/README.md) | CI agent image |

A service release uses one image digest across environments. The deployment job runs Helm tests and rolls back a failed release.

See [deploy a release](../docs/how-to/deploy.md).
