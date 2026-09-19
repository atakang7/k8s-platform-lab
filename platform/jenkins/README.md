# Jenkins

`platform/jenkins/` owns the Jenkins controller, Kubernetes agent templates, credentials wiring, and pipeline job definitions.

```text
Vault
  │ VSO
  ▼
Jenkins Secrets
  │
  ▼
┌────────────────────────┐
│ Jenkins controller     │
│ node-3 · 0 executors   │
│ JCasC                  │
└───────────┬────────────┘
            │
     ┌──────┴──────┐
     ▼             ▼
 CI runner      CD runner
 node-3         node-3
```

## Reconcile

```bash
make jenkins-up
```

The command creates/reuses the Vault identity, waits for VSO-managed Secrets, removes any legacy long-lived agent token, checks that neither agent identity has cluster-wide rights, and reconciles the pinned Helm release with JCasC.

Endpoint: `https://jenkins.lab.test`.

## JCasC ownership

`jcasc/jenkins.yaml` defines:

- zero controller executors;
- Kubernetes cloud configuration;
- exclusive `lab-ci-runner` and `lab-cd-runner` templates;
- GitHub and Docker Hub credentials (no cluster credential: CD mints short-lived tokens);
- the `lab-delivery` shared library (`delivery/pipeline`);
- a GitHub multibranch job per service and for `platform` (native commit statuses), plus the `deploy` job.

Do not make durable job, agent, or credential changes in the UI. Put them in JCasC/Vault and reconcile.

## CI agent image

The tools image is built from `delivery/jenkins/ci-agent.Dockerfile` and referenced by immutable digest in JCasC. Tooling changes require a new image, a new digest, and then `make jenkins-up`.

See [`delivery/README.md`](../../delivery/README.md) for pipeline behavior.
