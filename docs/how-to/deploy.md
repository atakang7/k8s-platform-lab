# Deploy a release

Jenkins owns application builds and deployments. The operator runs the initial [platform setup](bootstrap.md).

## Publish from main

1. Change a service and increment its chart version in [app/chart/Chart.yaml](../../app/chart/Chart.yaml) or [webhook Chart.yaml](../../policies/resource-requests-webhook/helm/resource-requests-webhook/Chart.yaml).
2. Open a pull request to `main`. Service CI tests, scans and validates the chart.
3. Merge after CI passes. The service pipeline publishes the image and chart, signs the image digest and updates `state/dev.yaml`.
4. The deploy job reads the new digest, verifies its signature, runs Helm and executes the chart tests.
5. Run `make e2e-validate` against the active dev cluster.

## Promote

The deploy job opens a state-only promotion pull request from dev to stage, then stage to prod after the preceding environment is healthy. Merge the promotion PR to update the next environment's [state](../reference/release-state.md).

Prod uses the canary values in [environments.yaml](../../environments.yaml). The deploy script queries the ingress 5xx rate through Prometheus.

```text
push -> test -> scan -> publish -> sign -> state -> deploy
```

The deploy job restores the prior Helm revision when release tests fail.
