Part of [k8s-platform-lab](../../README.md)

# Jenkins agent image

The CI agent image includes the tools used by the Jenkins build and scan stages.

## Run

From the repository root, after Docker login:

```sh
./delivery/jenkins/build-ci-agent.sh
make jenkins-up
```

## Config

| Variable | Default | Use |
| --- | --- | --- |
| `CI_AGENT_REPOSITORY` | `docker.io/atakangul/lab-ci-agent` | Published image repository |

## Interfaces

| Path | Purpose |
| --- | --- |
| [ci-agent.Dockerfile](ci-agent.Dockerfile) | Image toolchain |
| [build-ci-agent.sh](build-ci-agent.sh) | Build, push and resolve digest |
| [../../platform/jenkins/pods/](../../platform/jenkins/pods/) | Agent image pins |

The build script edits the Pod specs to use the published digest. Commit those changes before running `make jenkins-up`.
