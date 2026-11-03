Part of [k8s-platform-lab](../../README.md)

# Jenkins pipeline library

Shared Groovy stages call shell scripts shipped as Jenkins library resources.

## Run

Jenkins loads the library through `@Library('lab-delivery')`. Check shell syntax from the repository root:

```sh
bash -n delivery/pipeline/resources/lab/delivery/deploy.sh
bash -n delivery/pipeline/resources/lab/delivery/publish-image.sh
```

## Config

| Variable | Source | Use |
| --- | --- | --- |
| `APP_VERSION` | Chart.yaml | Version to publish |
| `IMAGE_DIGEST` | `state/<env>.yaml` | Immutable image |
| `NAMESPACE` | environments.yaml | Deploy target |
| `METRICS_URL` | environments.yaml | Canary queries |

## Interfaces

| Path | Purpose |
| --- | --- |
| [vars/servicePipeline.groovy](vars/servicePipeline.groovy) | Build, test, scan and publish |
| [vars/deployPipeline.groovy](vars/deployPipeline.groovy) | Verify and deploy Git state |
| [vars/delivery.groovy](vars/delivery.groovy) | Release helpers |
| [resources/lab/delivery/](resources/lab/delivery/) | Registry, scan and Helm scripts |

The publish path signs the registry digest. The deploy path verifies the signature and tests the Helm release.
