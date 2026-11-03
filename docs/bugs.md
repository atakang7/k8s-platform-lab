# Observed failures

These findings came from 17 fresh-VM runbook trials and snapshot recovery checks; see [test/README.md](../test/README.md).

## Fixed

- Shell and Ansible: `grep -q` with `pipefail` caused SIGPIPE false failures; output buffering, Python 3 pinning, `C.UTF-8`, and `vagrant up --provision` addressed setup failures.
- Worker capacity: node-2 lost SSH under load at 2 GiB, and node-3 could not schedule Grafana at 3 GiB; both now use 4 GiB.
- Test VM recovery: ejected cloud-init media, idempotent image handling, a 70 GiB disk cap, and paused-VM recovery addressed snapshot and disk failures.

## Open

- Grafana credentials: Helm generates a new admin password on reruns, changing `checksum/secret` and restarting Grafana; use a persistent `admin.existingSecret`.
- Grafana startup: liveness can restart the first launch before it completes; configure a startup probe before relying on rollback behavior.
- Jenkins restore: after `lab-test` snapshot recovery, chart 5.9.62's `yes n | cp -i` plugin copy can exit 1, and the Kubernetes provisioner was observed at 3/3 agents with zero nodes; the global cap must stay 3 while both failures are repaired.

The Jenkins incident was reproduced after snapshot restore, but not shown to occur on every restore.

## Verify

```bash
make cluster-validate
make edge-smoke
make observability-smoke
```

On a disposable `lab-test` VM with a `ready` snapshot, use `make test-vm-restore` followed by `make jenkins-up`; check the controller init logs and whether one agent of each configured class starts.
