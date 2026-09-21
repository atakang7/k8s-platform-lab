# Application

`app/` contains the sample Java service, its image, and the Helm values that describe how it runs.

```text
Ingress
  │
  ▼
sample-java-app Service :80
  │
  ▼
Java app :9001
  ├── /api/foos
  ├── /actuator/health/*
  └── /actuator/prometheus
```

Each Pod runs the Java application plus a Fluent Bit sidecar that ships the application's file log to Elasticsearch.

## Configuration

| File | Owns |
|---|---|
| `Dockerfile` | application image |
| `chart/Chart.yaml` | application/chart version and base-chart dependency |
| `chart/values.yaml` | shared/default runtime configuration |
| `chart/values-dev.yaml` | dev overrides |
| `chart/values-stage.yaml` | stage overrides |
| `Jenkinsfile` | connection to the shared delivery pipeline |

The chart inherits the shared [service base chart](../charts/service/README.md). Delivery supplies the immutable image digest when releasing it.

Current environment differences are intentionally small:

```text
dev      1 replica   app-dev.lab.test
stage    1 replica   app-stage.lab.test
prod     4 replicas  app.lab.test
```

Each cluster runs only the environment selected by `clusterEnvironment` in [`environments.yaml`](../environments.yaml).

## Runtime contract

The application:

- runs as non-root UID/GID `10001`;
- exposes readiness, liveness and startup probes;
- exports Prometheus metrics;
- declares CPU and memory requests/limits;
- uses worker-only placement;
- writes normal container logs and an application file log collected by the sidecar.

The four-replica configuration uses topology spreading across the workers and a PodDisruptionBudget with `minAvailable: 2`. Single-replica environment overrides disable that budget.

## Local checks

```bash
cd app
./mvnw test
./mvnw package
```

From the repository root:

```bash
make container-validate
```

## Release

The application version is `version` in `chart/Chart.yaml`.

Service CI builds, tests, scans and publishes the image/chart, then records the release in Git state. Deployment and promotion are owned by [DELIVERY.md](../DELIVERY.md); application configuration should not be changed with ad-hoc `kubectl` edits.
