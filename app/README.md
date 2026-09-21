# Application

The sample Java service is the workload used to exercise the platform end to end: container build, Kubernetes runtime, metrics, logs and delivery.

<div align="center">
<pre>
                         app.lab.test
                                │
                                ▼
                         ingress-nginx
                                │
                                ▼
                      sample-java-app :80
                                │
                                ▼
                     ┌──────────────────┐
                     │       Pod        │
                     │                  │
                     │  Java app :9001  │
                     │        │         │
                     │        └──────┐  │
                     │               ▼  │
                     │          Fluent Bit
                     └───────────────┬──┘
                                     │
                                     ▼
                               Elasticsearch
</pre>
</div>

## Image

```text
pom.xml + Maven wrapper
          │
          ▼
  dependency:go-offline      ← cache dependencies
          │
          ▼
       source
          │
          ▼
      JDK build
          │
          ▼
   application.jar
          │
          ▼
   minimal JRE image          ← runtime only
          │
          ▼
      UID 10001
```

- multi-stage build: JDK for build, JRE for runtime
- base images pinned by digest
- dependency layer separated from source for BuildKit cache reuse
- final image contains only the JRE + application JAR
- runtime is non-root; source revision is recorded in OCI labels

`.dockerignore` limits the build context to Maven metadata and application source.

## Runtime

```text
dev      1 replica   app-dev.lab.test
stage    1 replica   app-stage.lab.test
prod     4 replicas  app.lab.test
```

Each cluster runs only its `clusterEnvironment`.

The chart defines the runtime contract:

```text
startup / readiness / liveness probes
CPU + memory requests and limits
non-root + RuntimeDefault seccomp
worker-only placement
Prometheus /actuator/prometheus
```

Prod spreads four replicas across both workers and uses `minAvailable: 2`.  
Single-replica environments disable the disruption budget.

## Logging

The requirements require application logs to avoid stdout as the Elasticsearch forwarding path, write asynchronously, rotate daily and stay below 1 GB.

<div align="center">
<pre>
                         application logger
                         /              \
                        /                \
                       ▼                  ▼
                    stdout          AsyncAppender
                                             │
                                             ▼
                                  /var/log/app/app.log
                                             │
                                   daily + 100 MB rolls
                                   total history ≤ 1 GB
                                             │
                                             ▼
                                      Fluent Bit
                                             │
                                             ▼
                               Elasticsearch · app-logs
</pre>
</div>

`logback-spring.xml` owns asynchronous file writing and rotation.  
The chart mounts the shared `/var/log/app` volume and configures the Fluent Bit sidecar.

stdout remains available for normal Kubernetes troubleshooting; Elasticsearch forwarding reads the file instead.

## Configuration

| Change | File |
|---|---|
| image build | `Dockerfile` |
| application version | `chart/Chart.yaml` |
| runtime / logging | `chart/values.yaml` |
| dev / stage differences | `chart/values-<environment>.yaml` |
| application logging policy | `src/main/resources/logback-spring.xml` |
| CI entry point | `Jenkinsfile` |

The chart inherits [`charts/service`](../charts/service/README.md). Delivery injects the immutable image digest at release time.

## Verify

```bash
cd app
./mvnw test

# repository root
make container-validate
```

Release and promotion are documented in [DELIVERY.md](../DELIVERY.md).
