# service base chart

Library chart for a stateless HTTP service: Deployment, Service, and optional Ingress, ServiceMonitor and ConfigMaps. Apps inherit it; they don't copy it.

```yaml
# app/chart/Chart.yaml
dependencies:
  - name: service
    version: 1.0.0
    repository: oci://registry-1.docker.io/atakangul
```

```yaml
# app/chart/templates/service.yaml
{{ include "service.manifests" . }}
```

The app's `values.yaml` overrides the defaults in [`templates/_defaults.tpl`](templates/_defaults.tpl). `image.repository` is required; `image.digest` is set by delivery on every release and must be `sha256:<64 hex>`.

Released versions are immutable. Changing anything here needs a `version` bump in `Chart.yaml`; the `platform` job publishes it and fails if a released version's content changed.
