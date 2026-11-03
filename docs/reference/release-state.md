# Environment and release state

[environments.yaml](../../environments.yaml) defines the ordered environments and the one environment selected for this cluster.

| Field | Value | Meaning |
| --- | --- | --- |
| `clusterEnvironment` | `dev` | Environment run by this cluster |
| `chartRegistry` | `oci://registry-1.docker.io/atakangul` | Helm OCI repository |
| `metrics` | Prometheus service URL | Canary metric query target |
| `environments[].namespace` | `apps-dev`, `apps-stage`, `apps-prod` | Deployment namespaces |
| `releases[]` | `sample-java-app` | Jenkins-managed releases |

Each [state file](../../state/) has this shape:

```yaml
environment: dev
services:
  sample-java-app:
    version: 1.2.21
    image: sha256:<64-hex-character-digest>
```

The `image` field identifies the OCI artifact. A `null` service entry records no release.

Jenkins records newly published releases in `state/dev.yaml`; a promotion PR copies the version and digest to the next state file.
