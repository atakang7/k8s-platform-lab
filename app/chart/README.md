# Application Helm chart

`app/chart/` defines the stable application runtime and is the unit CD releases. `lab-deploy` installs it as Helm release `sample-java-app` in `default`.

```text
templates/deployment.yaml
    │
    ├──► 4 replicas
    ├──► worker-only placement
    ├──► topology spread
    ├──► probes + resources
    └──► Java + Fluent Bit sidecar

templates/service.yaml ──► :80 → :9001

templates/ingress.yaml ──► app.lab.test + wildcard TLS

templates/service-monitor.yaml ──► Prometheus scrape of /actuator/prometheus

templates/fluent-bit-config.yaml ──► file-log shipping to Elasticsearch
```

The templates are plain manifests. The only value is the image:

| Value | Meaning |
|---|---|
| `image.repository` | the only repository the chart accepts; must match `IMAGE_REPOSITORY` in `delivery/Jenkinsfile.build` |
| `image.reference` | `<repository>@sha256:<64 hex>`; the committed default is the known-good reference release, CD overrides it with the digest CI published |

Rendering fails for any other repository, for tags, and for anything that is not a full digest. The chart is the single owner of that check.

## Release behavior

`delivery/ci/deploy.sh` runs:

```text
helm upgrade --install sample-java-app app/chart
      --set-string image.reference=<IMAGE_REF>
      --rollback-on-failure --wait --timeout 3m
      --force-conflicts
```

- `--wait` succeeds only when every object is ready.
- `--rollback-on-failure` returns **all** chart objects to the last successful release when it is not.
- Release history is stored in ConfigMaps (`HELM_DRIVER=configmap`); CD has no access to Secrets in `default`.
- `--force-conflicts`: Helm owns these objects; fields last written by another manager (a manual `kubectl edit`) are taken back instead of failing the release.

The first release over objects that existed before the chart adopts them with `--take-ownership` and without rollback: rolling back a failed first install uninstalls it, which would delete the live objects.

Do not edit the committed `image.reference` to follow releases; release identity is the commit SHA + digest CD receives from CI.

## Validation

CI runs `helm lint app/chart`, renders the chart, and server-side dry-runs the result. That exercises schema validation and active admission policies without creating resources.
