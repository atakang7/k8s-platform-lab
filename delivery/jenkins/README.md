# Jenkins agent image

`delivery/jenkins/` owns the container image used by the Jenkins CI/CD Kubernetes agents.

```text
ci-agent.Dockerfile
       │
       ▼
build-ci-agent.sh
       │
       ▼
private registry
       │
       ▼
immutable image digest
       │
       ▼
platform/jenkins/jcasc/jenkins.yaml
       │
       ▼
lab-ci-runner / lab-cd-runner
```

The agent image contains the tools required by pipeline steps. BuildKit itself remains a separate privileged container in the CI Pod.

## Change procedure

1. Change `ci-agent.Dockerfile`.
2. Build and publish the new tools image.
3. Record its immutable registry digest.
4. Replace the digest in `platform/jenkins/jcasc/jenkins.yaml`.
5. Run `make jenkins-up`.

Do not change the live Pod template in Jenkins and leave JCasC behind. The digest in Git is the source of truth.
