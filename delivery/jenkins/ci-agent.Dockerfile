FROM maven:3.9.4-eclipse-temurin-17

ARG KUBECTL_VERSION=v1.36.2
ARG HADOLINT_VERSION=v2.14.0
ARG TRIVY_VERSION=0.45.0

USER root

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl git jq python3 python3-pip python3-venv skopeo \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && curl -fsSLo /usr/local/bin/hadolint \
      "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/hadolint-Linux-x86_64" \
 && chmod +x /usr/local/bin/hadolint \
 && curl -fsSL \
      "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
      | tar -xz -C /usr/local/bin trivy

RUN python3 -m venv /opt/ansible \
 && /opt/ansible/bin/pip install --no-cache-dir 'ansible-core==2.17.14' 'kubernetes>=30,<31' \
 && /opt/ansible/bin/ansible-galaxy collection install kubernetes.core \
 && ln -s /opt/ansible/bin/ansible /usr/local/bin/ansible \
 && ln -s /opt/ansible/bin/ansible-playbook /usr/local/bin/ansible-playbook \
 && ln -s /opt/ansible/bin/ansible-galaxy /usr/local/bin/ansible-galaxy

RUN mvn --version \
 && kubectl version --client=true \
 && hadolint --version \
 && trivy --version \
 && skopeo --version \
 && ansible-playbook --version

WORKDIR /home/jenkins/agent
CMD ["sh", "-c", "sleep infinity"]
