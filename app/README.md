Part of [k8s-platform-lab](../README.md)

# Sample Java app

A Java 21 Spring Boot service used to check releases, ingress, metrics and log shipping.

## Run

```sh
cd app
./mvnw test
./mvnw spring-boot:run
```

## Config

| Variable | Default | Use |
| --- | --- | --- |
| `SERVER_PORT` | `9001` | HTTP listener |
| `server.shutdown` | `graceful` | Shutdown behavior |
| `spring.lifecycle.timeout-per-shutdown-phase` | `20s` | Shutdown deadline |

Defaults are in [application.properties](src/main/resources/application.properties).

## Interfaces

| Path | Response |
| --- | --- |
| `GET /api/foos?val=hello` | `QueryStringValue: hello` |
| `GET /api/release` | Literal release string |
| `GET /actuator/health/liveness` | Liveness probe |
| `GET /actuator/health/readiness` | Readiness probe |
| `GET /actuator/prometheus` | Prometheus metrics |

[chart/](chart/README.md) owns Kubernetes deployment values. [Dockerfile](Dockerfile) runs the service as UID 10001.
