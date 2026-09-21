# Application

`app/` is the sample Java service used to exercise the platform end to end. It owns the application source, container image, runtime values and application-side logging. Delivery owns how a released image moves between environments.

<div align="center">
<pre>
Client
  │
  ▼
Ingress
  │
  ▼
sample-java-app Service :80
  │
  ▼
Pod
├── Java application :9001
│   ├── /api/foos
│   ├── /actuator/health/*
│   └── /actuator/prometheus
│
└── Fluent Bit sidecar
    └── application file logs → Elasticsearch
</pre>
</div>

## Configuration

| File | Owns |
|---|---|
| `Dockerfile` | application image |
| `chart/Chart.yaml` | application version and base-chart dependency |
| `chart/values.yaml` | default runtime configuration |
| `chart/values-dev.yaml` | dev overrides |
| `chart/values-stage.yaml` | stage overrides |
| `Jenkinsfile` | entry into the shared delivery pipeline |

The application chart inherits the shared [service base chart](../charts/service/README.md). Delivery injects the immutable image digest at release time.

## Container image

The Dockerfile is structured around the requirements: fast rebuilds, a small runtime image and a non-root process.

<div align="center">
<pre>
pom.xml + Maven wrapper
        │
        ▼
dependency:go-offline
        │
        │ cached while dependencies stay unchanged
        ▼
     source code
        │
        ▼
   JDK build stage
        │
        ▼
  application.jar
        │
        ▼
minimal JRE runtime
        │
        ▼
   UID/GID 10001
</pre>
</div>

Both base images are pinned by digest. The final image contains only the JRE and application JAR — no Maven, JDK, compiler tooling or source tree.

`.dockerignore` keeps the build context limited to Maven metadata and source files. Combined with the dependency-first Dockerfile layout and persistent BuildKit state in CI, unchanged dependencies remain cacheable across builds.

CI also stamps the image with the source repository and source revision through OCI labels.

## Runtime

Environment-specific values change capacity and hostname without changing the artifact:

<div align="center">
<pre>
dev      1 replica   app-dev.lab.test
stage    1 replica   app-stage.lab.test
prod     4 replicas  app.lab.test
</pre>
</div>

Each cluster runs only the environment selected by `clusterEnvironment` in [`environments.yaml`](../environments.yaml).

The runtime contract is defined in the chart values: non-root execution, startup/readiness/liveness probes, CPU and memory requests/limits, Prometheus metrics and worker-only placement.

The four-replica configuration is spread across both workers and uses a PodDisruptionBudget with `minAvailable: 2`. Single-replica environments disable that budget.

## Application logging

The requirements specifically ask to move log forwarding away from stdout because of its performance impact. The application therefore keeps stdout for normal Kubernetes troubleshooting, while the Elasticsearch path is built around an asynchronous file.

<div align="center">
<pre>
                    application logger
                         │
              ┌──────────┴──────────┐
              ▼                     ▼
            stdout             AsyncAppender
       Kubernetes view              │
                                    ▼
                           /var/log/app/app.log
                                    │
                          daily + size rotation
                          retained history ≤ 1 GB
                                    │
                                    ▼
                           Fluent Bit sidecar
                                    │
                                    ▼
                        Elasticsearch · app-logs
</pre>
</div>

The implementation is split cleanly between the application and its chart:

| Requirement | Implementation |
|---|---|
| asynchronous file writes | Logback `AsyncAppender` |
| daily rotation | `SizeAndTimeBasedRollingPolicy` date pattern |
| bounded files | 100 MB per rolled file |
| maximum retained logs | `totalSizeCap: 1GB` |
| forwarding | Fluent Bit sidecar tails the shared log volume |
| destination | Elasticsearch index `app-logs` |

The Java container and Fluent Bit share `/var/log/app` through an `emptyDir`. Elasticsearch forwarding therefore does not depend on stdout.

## Check and release

Local application checks:

```bash
cd app
./mvnw test
./mvnw package
```

Container contract:

```bash
make container-validate
```

The release version is `version` in `chart/Chart.yaml`. CI builds, tests, scans and publishes the image/chart, then records the immutable release in Git state.

See [DELIVERY.md](../DELIVERY.md) for deployment and promotion.
