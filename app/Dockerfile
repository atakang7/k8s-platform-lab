FROM eclipse-temurin:11.0.32_9-jdk-jammy@sha256:d47c552b2078dcb4d21471c3914194d501f351d7e85ec18a3f2bb1e452adecf9 AS build

WORKDIR /workspace

COPY .mvn/ .mvn/
COPY mvnw pom.xml ./
RUN sh ./mvnw --batch-mode --no-transfer-progress dependency:go-offline

COPY src/ src/
RUN sh ./mvnw --batch-mode --no-transfer-progress package \
&& cp target/app-0.0.1-SNAPSHOT.jar /workspace/application.jar

FROM eclipse-temurin:11.0.32_9-jre-ubi9-minimal@sha256:6bca03a0f51a7b8af331c3c5db0cfc47d5f5853dda33b5a125031d08250c3f88

ARG SOURCE_REPOSITORY=unknown
ARG SOURCE_REVISION=unknown

LABEL org.opencontainers.image.source="${SOURCE_REPOSITORY}" \
      org.opencontainers.image.revision="${SOURCE_REVISION}"

WORKDIR /app

RUN mkdir -p /var/log/app && chown 10001:10001 /var/log/app

COPY --from=build --chown=10001:10001 /workspace/application.jar ./application.jar

USER 10001:10001
EXPOSE 9001

ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/application.jar"]
