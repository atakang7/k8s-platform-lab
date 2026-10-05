# Weaknesses

Known gaps, accepted for a one-laptop lab. Each says what production would do.
Open bugs are in [bugs.md](bugs.md).

**1. One control plane**
- Accepted: node-1 runs the only API server and etcd. If it dies, nothing can be deployed or changed.
- Production: three control-plane nodes and etcd backups.

**2. One Vault on one host, unsealed by hand**
- Accepted: the root token is kept in a file, and losing the host loses every secret.
- Production: HA Vault with auto-unseal; the root token revoked; operators log in with their own identity.

**3. Vault and BIND are not monitored**
- Accepted: only `make edge-smoke` and `make edge-validate` check them, and only when run. Their logs stay on the host.
- Production: Vault telemetry and a BIND exporter scraped by Prometheus, with "Vault sealed" and "BIND down" alerts.

**4. The cluster can't lose a worker**
- Accepted: one 4 GiB worker can't hold both workers' pods (no N+1 capacity).
- Production: room for one node to fail, ResourceQuotas per namespace, PriorityClasses for what matters.

**5. MetalLB L2 sends all traffic through one node**
- Accepted: one node answers ARP for each IP. The other only takes over when it dies.
- Production: BGP mode with a router, so traffic spreads across nodes.

**6. Data dies with a node**
- Accepted: local-path volumes live on one node's disk; Elasticsearch has one node and no replicas; Prometheus keeps 1 day.
- Production: network storage (CSI), replicas, backups.

**7. Few alerts**
- Accepted: only pod restarts alert. Nothing alerts on the app's 5xx rate or latency.
- Production: SLO alerts on error rate and latency that page someone.

**8. One wildcard certificate from a lab CA**
- Accepted: one key covers every host, and only machines that trust the lab CA trust it.
- Production: cert-manager with a certificate per host from a trusted CA.

**9. CI builds share nodes with the app**
- Accepted: a Jenkins build on node-3 can starve what runs next to it.
- Production: separate build nodes.

**10. Registry credentials sit in a Kubernetes Secret**
- Accepted: anyone who can read Secrets in `jenkins` can read the Docker Hub token.
- Production: tight RBAC on that namespace, and agents that fetch the token only during a build.

**11. Only dev runs in the lab**
- Accepted: stage, prod, promotion and the canary are defined but never run on this cluster.
- Production: one cluster per environment.

**12. The canary passes with no traffic**
- Accepted: if the canary gets no measurable traffic, the deploy warns and continues.
- Production: require enough traffic, or generate synthetic traffic, before promoting.

**13. The burn-in doesn't test a new release**
- Accepted: `state/dev.yaml` already holds the release, so fresh runs rebuild and redeploy it but never record a new one.
- Production: a test run that bumps the version and follows it from build to deploy.
