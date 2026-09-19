# service base chart

Library chart for a stateless HTTP service: Deployment, Service, a Helm smoke test, and optional Ingress, ServiceMonitor, ConfigMaps, and PodDisruptionBudget. Apps inherit it instead of copying platform boilerplate.

A consumer calls the library once:

```yaml
# templates/service.yaml
{{ include "service.manifests" . }}
```

and pins a published library version in its chart dependency:

```yaml
dependencies:
  - name: service
    version: 1.2.0
    repository: oci://registry-1.docker.io/atakangul
```

The app's `values.yaml` overrides the defaults in [`templates/_defaults.tpl`](templates/_defaults.tpl). `image.repository` is required; `image.digest` is set by delivery on every release and must be `sha256:<64 hex>`.

## Runtime defaults

The base chart is deliberately conservative and explicit:

```text
image pull          IfNotPresent
API token mount     disabled
service links       disabled
termination grace   30s
topology spread     enabled
PDB                 opt-in
```

Applications can override these values when they have a real requirement. In particular, a service that needs Kubernetes API credentials must opt into service-account token mounting rather than receiving ambient credentials by default.

PDB support is opt-in because the correct availability budget depends on replica count and cluster capacity:

```yaml
podDisruptionBudget:
  enabled: true
  minAvailable: 2
```

## Smoke test

Every release carries a Helm test that sends one request through the Service to `smokeTest.path` and expects a 2xx answer. Delivery runs it after each deploy and rolls the release back when it fails. Point it at a real endpoint, not only a health check:

```yaml
smokeTest:
  path: /api/foos
```

Further Helm test hooks in the app chart run with it; they are the service's end-to-end tests.

## Release rule

Released versions are immutable. Pull requests that change this chart must bump `version` in `Chart.yaml`; chart-testing enforces the version increment. The main platform job publishes a version only when that exact version is absent from the OCI registry.
