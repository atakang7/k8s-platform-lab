# Jenkins agent image

`delivery/jenkins/` owns the container image used by the Jenkins CI/CD Kubernetes agents.

```text
ci-agent.Dockerfile
       │
       ▼
build-ci-agent.sh
       │
       ▼
Docker Hub · dockerfile-<content hash> tag
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

The agent image contains the tools required by pipeline steps. BuildKit itself is a separate rootless (uid 1000, unprivileged) container in the CI Pod.

## Change procedure

1. Change `ci-agent.Dockerfile`. Pin every downloaded binary by version **and** SHA-256 in its `ARG`s.
2. Commit the Dockerfile.
3. Run `delivery/jenkins/build-ci-agent.sh`. It refuses uncommitted Dockerfile edits, builds, pushes
   `…/lab-ci-agent:dockerfile-<content hash>`, and writes the pushed digest into
   `platform/jenkins/jcasc/jenkins.yaml`.
4. Commit the JCasC change in the same pull request and run `make jenkins-up`.

Do not change the live Pod template in Jenkins and leave JCasC behind. The digest in Git is the source of truth.
