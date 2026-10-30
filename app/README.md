# Application

The sample Java service exercises the full platform: image build,
Kubernetes runtime, ingress, health, metrics, logs, and delivery.

## 1. Runtime path

~~~text
app*.lab.test
        │
        ▼
┌────────────────────┐
│ ingress-nginx      │
└─────────┬──────────┘
          ▼
┌────────────────────┐
│ Service :80        │
└─────────┬──────────┘
          ▼
┌────────────────────┐
│ application Pod    │
│ Java :9001         │
└─────────┬──────────┘
          │
     ┌────┴─────┐
     │          │
     ▼          ▼
 response     metrics
                │
                ▼
          Prometheus
~~~

The application endpoint is:

~~~text
GET /api/foos?val=<value>
        │
        ▼
QueryStringValue: <value>
~~~

The same request value is also written to the application log.

## 2. Image build

~~~text
pom.xml + Maven wrapper
          │
          ▼
dependency:go-offline
          │
          │ cached separately
          ▼
application source
          │
          ▼
JDK build stage
          │
          ▼
unit tests + package
          │
          ▼
application.jar
          │
          ▼
minimal JRE stage
          │
          ▼
non-root UID 10001
~~~

The runtime image contains only the JRE and application JAR.

~~~text
BUILD IMAGE
JDK + Maven
source + tests
     │
     │ COPY jar only
     ▼
RUNTIME IMAGE
minimal JRE
application.jar
UID 10001
~~~

Both base images are pinned by digest. Dependency metadata is copied
before source so BuildKit can reuse the Maven dependency layer.

OCI labels record the source repository and source revision.

**Source:** [Dockerfile](Dockerfile)

## 3. Environment profiles

~~~text
dev
1 replica
app-dev.lab.test
PDB disabled
maxSurge: 1


stage
1 replica
app-stage.lab.test
PDB disabled
maxSurge: 1


prod / base profile
4 replicas
app.lab.test
PDB minAvailable: 2
maxSurge: 4
~~~

Each cluster runs only the profile matching its
`clusterEnvironment`.

The four-replica base/prod profile spreads Pods across the two workers.

## 4. Pod runtime contract

~~~text
application Pod
      │
      ├── worker-only placement
      ├── CPU / memory requests
      ├── CPU / memory limits
      ├── non-root UID 10001
      ├── no privilege escalation
      ├── drop ALL capabilities
      ├── RuntimeDefault seccomp
      └── health probes
~~~

Resources:

~~~text
request   250m CPU / 256Mi
limit     500m CPU / 512Mi
~~~

The shared service chart also disables unnecessary service-account token
mounting and service links.

## 5. Health path

~~~text
Pod starts
   │
   ▼
startup probe
/liveness
   │ pass
   ▼
readiness probe
/readiness
   │ pass
   ▼
Service traffic
   │
   ▼
liveness probe
/liveness
~~~

Readiness controls traffic. Liveness restarts a broken process. Startup
gives the JVM time to initialize before normal liveness behavior applies.

## 6. Rolling update

~~~text
stable Pods
    │
    ▼
new Pod starts
    │
    ▼
startup passes
    │
    ▼
readiness passes
    │
    ▼
new Pod receives traffic
    │
    ▼
old Pod terminates
~~~

The base/prod profile uses:

~~~text
maxUnavailable: 0
maxSurge: 4
~~~

Dev/stage keep the same zero-unavailable rule with `maxSurge: 1`.

## 7. Logging

The Elasticsearch forwarding path does not read stdout.

~~~text
                  application logger
                         │
              ┌──────────┴──────────┐
              │                     │
              ▼                     ▼
        CONSOLE appender       ASYNC_FILE
        WARN + ERROR only     every level
              │                     │
              ▼                     ▼
        Kubernetes stdout   RollingFileAppender
                                  │
                                  ▼
                         /var/log/app/app.log
                                  │
                         ┌────────┴────────┐
                         │ rotation policy │
                         │ daily           │
                         │ max file 100 MB │
                         │ total cap 1 GB  │
                         └────────┬────────┘
                                  ▼
                         Fluent Bit sidecar
                                  │
                                  ▼
                         Elasticsearch
                         app-logs
~~~

Every line goes to the asynchronous file; stdout gets WARN and ERROR only.
Request logging stays off the slow stdout path, and `kubectl logs` still
shows failures. Container validation fails if a request line reaches stdout.

**Source:** [logback-spring.xml](src/main/resources/logback-spring.xml)

## 8. Shared log volume

~~~text
┌──────────────────────────────┐
│ application Pod              │
│                              │
│  ┌────────────┐              │
│  │ Java app   │              │
│  └─────┬──────┘              │
│        │ writes              │
│        ▼                     │
│  /var/log/app                │
│  emptyDir                    │
│        │                     │
│        │ reads               │
│  ┌─────▼──────┐              │
│  │ Fluent Bit │              │
│  │ sidecar    │              │
│  └─────┬──────┘              │
└────────┼─────────────────────┘
         ▼
   Elasticsearch
~~~

The application and Fluent Bit sidecar share the same `emptyDir`
volume.

## 9. Metrics

~~~text
Java app
   │
   ▼
/actuator/prometheus
   │
   ▼
ServiceMonitor
   │
   ▼
Prometheus
   │
   ▼
Grafana
~~~

Metrics are enabled by the application values and consumed by the
platform observability stack.

## 10. Delivery boundary

~~~text
application source
      │
      ▼
Jenkins CI
      │
      ▼
image digest
      │
      ▼
state/<env>.yaml
      │
      ▼
delivery injects digest
      │
      ▼
service chart
      │
      ▼
running Pod
~~~

The chart never chooses a mutable image tag at deploy time. Delivery
injects the immutable digest recorded in environment state.

See **[DELIVERY.md](../DELIVERY.md)** for the release path.

## 11. Main files

| Change | File |
|---|---|
| application code | `src/` |
| image build | `Dockerfile` |
| application version | `chart/Chart.yaml` |
| base/prod runtime | `chart/values.yaml` |
| dev overrides | `chart/values-dev.yaml` |
| stage overrides | `chart/values-stage.yaml` |
| logging policy | `src/main/resources/logback-spring.xml` |
| CI entry point | `Jenkinsfile` |

The application chart inherits the shared
**[service chart](../charts/service/README.md)**.

## 12. Verify

Run unit tests:

~~~bash
cd app
./mvnw test
~~~

Validate the built container from repository root:

~~~bash
make container-validate
~~~
