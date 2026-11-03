# Jenkins agent image

`delivery/jenkins/` owns the image used by Jenkins Kubernetes agents.

## 1. Image lifecycle

~~~text
ci-agent.Dockerfile
        │
        ▼
committed recipe
        │
        ▼
build-ci-agent.sh
        │
        ▼
build image
        │
        ▼
push registry tag
dockerfile-<hash>
        │
        ▼
resolve immutable digest
        │
        ▼
update Jenkins JCasC
        │
        ▼
new agent Pods
~~~

The mutable-looking content-hash tag is only a build-recipe identifier.
The registry digest written into JCasC is the runtime identity.

## 2. Agent Pod shape

~~~text
Jenkins agent Pod
       │
       ├── ci-agent
       │   tools used by Pipeline
       │
       └── BuildKit
           rootless
           UID 1000
           unprivileged
~~~

BuildKit is deliberately a separate container. The main CI agent does not
need to become a privileged Docker-in-Docker container.

## 3. Change procedure

~~~text
edit ci-agent.Dockerfile
        │
        ▼
pin downloaded tools
version + SHA256
        │
        ▼
commit Dockerfile
        │
        ▼
run build-ci-agent.sh
        │
        ▼
push image
        │
        ▼
write digest into
Jenkins JCasC
        │
        ▼
commit JCasC change
        │
        ▼
make jenkins-up
~~~

The build script refuses uncommitted Dockerfile edits. The recipe and
the JCasC digest change therefore stay reviewable together.

## 4. Why the digest matters

~~~text
dockerfile-<content hash>
        │
        │ identifies recipe
        ▼
rebuild later
        │
        ├── package repos may differ
        └── package contents may differ


registry digest
        │
        ▼
exact image Jenkins runs
~~~

The Dockerfile pins downloaded binaries, but distribution packages are
not all frozen to exact package versions. The content-hash tag therefore
does not claim bit-for-bit reproducibility.

The immutable digest is the execution identity.

## 5. Source-of-truth path

~~~text
delivery/jenkins/
ci-agent.Dockerfile
        │
        ▼
build-ci-agent.sh
        │
        ▼
platform/jenkins/
pods/*.yaml
        │
        ▼
Kubernetes agent template
        │
        ▼
running agent Pod
~~~

Do not modify the live Jenkins Pod template and leave JCasC behind.

Git is the source of truth.

## 6. Reconcile

After the Dockerfile and JCasC digest are committed:

~~~bash
make jenkins-up
~~~

Jenkins reconciliation removes stale agent Pods after template changes,
so new builds cannot continue on the previous agent image.

For controller and agent execution details, see
**[platform/jenkins/README.md](../../platform/jenkins/README.md)**.
