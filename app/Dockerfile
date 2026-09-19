FROM eclipse-temurin:21.0.12_8-jdk-jammy@sha256:c7d5863b5dd8f26b90c64f1d80cc2b0e5a5e4642f8db9955a370d348edd8f438 AS build

WORKDIR /workspace

COPY .mvn/ .mvn/
COPY mvnw pom.xml ./
RUN sh ./mvnw --batch-mode --no-transfer-progress dependency:go-offline

COPY src/ src/
RUN sh ./mvnw --batch-mode --no-transfer-progress package \
&& cp target/app-0.0.1-SNAPSHOT.jar /workspace/application.jar

FROM eclipse-temurin:21.0.12_8-jre-ubi9-minimal@sha256:12f0fdd1ebb06c0c480353ec2d3855cca638462f531c9eb03981321629010511

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
