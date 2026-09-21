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


## Image

The Dockerfile directly addresses the requirements for build speed, image size and security:

```text
JDK build image
   │
   ├── copy Maven wrapper + pom.xml
   ├── dependency:go-offline
   │      └── cached until dependencies change
   ├── copy source
   └── package
          │
          ▼
       application.jar
          │
          ▼
minimal JRE runtime image
   └── non-root UID 10001
```

The build and runtime base images are pinned by digest. Only the JAR is copied into the final JRE image, so Maven, the JDK and source code do not ship in the runtime container.

`.dockerignore` keeps the build context limited to Maven metadata and application source. CI also reuses BuildKit state, so unchanged dependency and build layers do not need to be rebuilt.

The runtime process runs as UID/GID `10001`, and CI injects the source repository and revision as OCI labels.


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
- uses worker-only placement.

The four-replica configuration uses topology spreading across the workers and a PodDisruptionBudget with `minAvailable: 2`. Single-replica environment overrides disable that budget.


## Application logs

The requirements call out the cost of using stdout as the log-forwarding path. The Elasticsearch path therefore uses an asynchronous file instead:

```text
application logger
      │
      ├──► stdout
      │     Kubernetes-native troubleshooting
      │
      └──► AsyncAppender
                │
                ▼
        /var/log/app/app.log
                │
        daily + size rotation
        total history ≤ 1 GB
                │
                ▼
        Fluent Bit sidecar
                │
                ▼
        Elasticsearch · app-logs
```

`logback-spring.xml` implements the file side:

- `AsyncAppender` keeps file I/O off the request thread;
- `SizeAndTimeBasedRollingPolicy` rotates by date;
- each file is capped at 100 MB;
- retained log history is capped at 1 GB.

The application and Fluent Bit sidecar share `/var/log/app` through an `emptyDir`. Fluent Bit tails the files and sends them directly to the `app-logs` Elasticsearch index.

stdout is still kept as the normal Kubernetes console stream, but Elasticsearch forwarding does not depend on stdout.


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
