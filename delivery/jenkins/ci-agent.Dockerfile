# Build only through delivery/jenkins/build-ci-agent.sh: it refuses uncommitted
# changes and pins the resulting digest in JCasC, so the running image always
# corresponds to this file in Git.
FROM maven:3.9.4-eclipse-temurin-17@sha256:e3f36fd6d0949541de3b6a32bb3de30331b2bdb6bac8ba365c4f8a5f0fcd3e59

# Checksums are pinned here, not fetched beside the binary, so a replaced
# upstream artifact fails the build instead of entering the image.
ARG KUBECTL_VERSION=v1.36.2
ARG KUBECTL_SHA256=1e9045ec32bea85da43de85f0065358529ea7c7a152eca78154fba5b58c27d82
ARG HADOLINT_VERSION=v2.14.0
ARG HADOLINT_SHA256=6bf226944684f56c84dd014e8b979d27425c0148f61b3bd99bcc6f39e9dc5a47
ARG TRIVY_VERSION=0.74.0
ARG TRIVY_SHA256=2ae6fe3ee734b7fdf11335663e18c75ea12dccc76062f09f164a3b0f8be4371a
ARG HELM_VERSION=v4.3.0
ARG HELM_SHA256=86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb

USER root

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl git jq python3 skopeo \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && echo "${KUBECTL_SHA256}  /usr/local/bin/kubectl" | sha256sum -c - \
 && chmod +x /usr/local/bin/kubectl \
 && curl -fsSLo /usr/local/bin/hadolint \
      "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/hadolint-Linux-x86_64" \
 && echo "${HADOLINT_SHA256}  /usr/local/bin/hadolint" | sha256sum -c - \
 && chmod +x /usr/local/bin/hadolint \
 && curl -fsSLo /tmp/trivy.tar.gz \
      "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
 && echo "${TRIVY_SHA256}  /tmp/trivy.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/trivy.tar.gz -C /usr/local/bin trivy \
 && rm /tmp/trivy.tar.gz \
 && curl -fsSLo /tmp/helm.tar.gz "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
 && echo "${HELM_SHA256}  /tmp/helm.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/helm.tar.gz -C /usr/local/bin --strip-components=1 linux-amd64/helm \
 && rm /tmp/helm.tar.gz

RUN mvn --version \
 && kubectl version --client=true \
 && hadolint --version \
 && trivy --version \
 && skopeo --version \
 && helm version

WORKDIR /home/jenkins/agent
CMD ["sh", "-c", "sleep infinity"]
