Part of [k8s-platform-lab](../../README.md)

# Jenkins

Jenkins runs repository jobs on Kubernetes agents with separate CI and deployment identities.

## Run

```sh
make jenkins-up
make endpoints
make credentials
```

## Config

| File | Default | Use |
| --- | --- | --- |
| [versions.env](versions.env) | `5.9.62` | Jenkins Helm chart |
| [values.yaml](values.yaml) | `node-3` | Controller node |
| [pods/](pods/) | `ci-runner`, `ci-light`, `cd-runner` | Agent templates |
| [jcasc/](jcasc/) | YAML | Jenkins configuration |

## Interfaces

| Path | Purpose |
| --- | --- |
| [bin/up](bin/up) | Secret sync and Helm install |
| [jobs.groovy](jobs.groovy) | Multibranch job definitions |
| [resources/agent-rbac.yaml](resources/agent-rbac.yaml) | CI agent permissions |
| [../../delivery/](../../delivery/README.md) | Build and deployment pipelines |

The controller is available at `https://jenkins.lab.test` after host DNS and CA setup.
