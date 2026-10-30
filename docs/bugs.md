# Bugs

Found by 17 full runs of the runbook in a fresh test VM and subsequent snapshot-recovery debugging ([test/README.md](../test/README.md)).

**1. `| grep -q` and `| head` report false failures** · `d3f2e84`, `4bfc4fb`
- Found: `DNS read policy is absent`, but `vault policy read dns-read` showed the policy.
- Cause: `grep -q` exits early, the writer is killed by SIGPIPE (exit 141), and `pipefail` fails the line.
- Fix: save the output first, then match. A scan fixed three more scripts with the same bug.

**2. node-2 drops SSH during edge validation** · `493c958`, `5f37264`
- Found: `node-2 SSH is unavailable` in 6 of 16 runs, always right after `make edge-up`.
- Cause: a busy node-2 drops the session; `ConnectionAttempts` only retries the TCP connect, and Vagrant's `LogLevel FATAL` hid the error.
- Fix: retry the whole SSH command for a minute with `LogLevel=ERROR`; Ansible `timeout = 60`, `retries = 3`. The node SSH check was later dropped when validation was shortened.

**3. node-2 runs out of memory** · `a73cc9a`
- Found: 47 MB free of 2 GiB, load average 31 on 2 CPUs.
- Cause: ingress, MetalLB, Prometheus and Fluent Bit don't fit in 2 GiB.
- Fix: node-2 gets 4 GiB in the `Vagrantfile`; the test VM gets 13 GiB.

**4. Grafana can't be scheduled on node-3**
- Found: `FailedScheduling: 0/3 nodes are available: 1 Insufficient memory`.
- Cause: at 3 GiB, Jenkins and three CI agents reserved node-3's memory (requests).
- Fix: node-3 stays at 4 GiB.

**5. Ansible picks a Python that doesn't exist** · `edb30d7`
- Found: `/usr/bin/python: not found` on node-2 at `Gathering Facts`.
- Cause: discovery timed out on the busy node and `auto_silent` fell back to `/usr/bin/python`.
- Fix: `interpreter_python = /usr/bin/python3`.

**6. Ansible won't start over SSH** · `14d7811`
- Found: `could not initialize the preferred locale`.
- Cause: SSH forwards the host's `tr_TR` locale, which the VM doesn't have.
- Fix: `test/bin/runbook` sets `LC_ALL=C.UTF-8`.

**7. A rerun skips Ansible on existing VMs** · `23d3ac4`
- Found: `Machine already provisioned`, then the same failure again.
- Cause: plain `vagrant up` only provisions new VMs.
- Fix: `make cluster-up` runs `vagrant up --provision`.

**8. Snapshot restore looks for a deleted CD** · `14d7811`
- Found: `Cannot access storage file …/virtinst-…-cloudinit.iso`.
- Cause: virt-install deletes its cloud-init CD, but the running VM, and so the snapshot, keeps it attached.
- Fix: `test/bin/up` ejects it with `virsh change-media … --eject --live`.

**9. A rerun breaks the running test VM's disk** · `14d7811`
- Found: `Input/output error` in the VM; the Ubuntu image was 318 MB of 596 MB.
- Cause: a rerun downloaded over the image the running VM's disk reads from.
- Fix: `test/bin/up` is idempotent and never replaces an existing image.

**10. A full host disk freezes the test VM** · `14d7811`
- Found: `No route to host`; `virsh domstate --reason` showed `paused (I/O error)`.
- Cause: the thin VM disk grew until the host disk was full.
- Fix: a 70 GiB disk cap, the host space in the README, and `test/bin/up` resumes a paused VM.

**11. Grafana restarts on every rerun (open)**
- Cause: no admin password is set, so each Helm render makes a new one and changes `checksum/secret`.
- Fix planned: a `grafana-admin` Secret created once, used via `admin.existingSecret`.

**12. Grafana is killed during its first start (open)**
- Cause: with no startup probe, liveness restarts it mid-start, and `--rollback-on-failure` uninstalls the release.
- Fix planned: a Grafana `startupProbe`.

**13. Jenkins controller and agents fail after VM snapshot restore (open)**

Restoring the test VM can leave Jenkins unable to recover: the controller init container exits while copying existing plugins, and after controller recovery the Kubernetes provisioner can still count three agents even though no agents exist. CI/CD warm-up jobs remain queued indefinitely.

### Environment

- Test VM: `lab-test`, restored with `make test-vm-restore`.
- Restore command: `virsh -c qemu:///system snapshot-revert lab-test ready --running`.
- Kubernetes: 1.34.1; all three nodes were Ready, with no memory or disk pressure.
- Jenkins Helm chart: 5.9.62.
- Controller image: `jenkins/jenkins:2.568.3-jdk21`.
- Jenkins Kubernetes cloud: global agent cap 3, static template instance caps 1.
- Configuration: [values.yaml](https://github.com/atakang7/k8s-platform-lab/blob/main/platform/jenkins/values.yaml), [JCasC agent templates](https://github.com/atakang7/k8s-platform-lab/blob/main/platform/jenkins/jcasc/agents.yaml), [warm-up jobs](https://github.com/atakang7/k8s-platform-lab/blob/main/platform/jenkins/jobs.groovy).

### Observed sequence

1. Restore the `ready` snapshot.
2. Most cluster workloads recover, but `jenkins-0` and the three old agent pods show `Unknown`.
3. `make jenkins-up` passes Vault secret synchronization and the CI permission check, then Helm waits 10 minutes for `StatefulSet/jenkins`. Both the upgrade and rollback time out at `Ready: 0/1`.
4. The controller init container repeatedly exits with code 1. Plugin installation completes; the next copy step fails.
5. Recreating the controller pod allowed initialization to complete and the controller became `1/1 Running`.
6. The old warm-up builds waited for offline agents. Aborting those builds produced fresh timer runs, but the fresh runs still waited for an executor and no agent pods were created.
7. Live provisioner inspection showed a stale global count of 3 with zero Jenkins agent nodes.
8. Restoring the snapshot again reproduced the controller init failure. At that inspection the init container had 25 failed restarts; the old agent containers were terminated with exit code 255 and reason `Unknown`.

This is an observed incident sequence, not a claim that every healthy snapshot deterministically reproduces it.

### Failure 1: upstream plugin-copy step is not restart-safe

The chart-generated `apply_config.sh` contains:

```sh
set -e
# ...
yes n | cp -i /usr/share/jenkins/ref/plugins/* /var/jenkins_plugins/
```

This command comes from the [upstream chart 5.9.62 template](https://github.com/jenkinsci/helm-charts/blob/jenkins-5.9.62/charts/jenkins/templates/config.yaml#L43-L45), not a copy command authored in this repository.

The init log ends with:

```text
Done
copy plugins to shared volume
cp: overwrite '/var/jenkins_plugins/antisamy-markup-formatter.jpi'?
cp: overwrite '/var/jenkins_plugins/apache-httpcomponents-client-4-api.jpi'?
...
```

The automatic negative answers decline the copies. In the observed image this ends with exit code 1, so `set -e` prevents initialization from completing. The plugin destination is an `emptyDir`: files can survive container retries within the same pod, while recreating the pod gives it fresh temporary storage.

### Failure 2: stale global provisioning count blocks replacement agents

Read-only inspection of the running controller returned:

```json
{
  "quietingDown": false,
  "cloudCap": 3,
  "cloudCount": 3,
  "nodes": [],
  "templates": [
    {"name": "ci-runner", "cap": 1, "count": 0},
    {"name": "ci-light", "cap": 1, "count": 0},
    {"name": "cd-runner", "cap": 1, "count": 0}
  ]
}
```

All three requested labels matched templates. Pending launches were empty. The controller service account could both create and list pods in the Jenkins namespace.

Fresh warm-up logs showed:

```text
Started by timer
[Pipeline] node
Still waiting to schedule task
Waiting for next available executor
```

The stale global count consumes the entire configured cap, preventing any new registration despite zero actual agents. Aborting warm-up builds does not reset this counter.

The [upstream provisioning-limit implementation](https://github.com/jenkinsci/kubernetes-plugin/blob/master/src/main/java/org/csanchez/jenkins/plugins/kubernetes/KubernetesProvisioningLimits.java) initializes counts from saved agent nodes and unregisters deleted nodes only when their pod template can be resolved. Investigate template identity across JCasC reloads, restored nodes, and dynamic CD templates. Our static templates currently have no explicit stable IDs. The precise source of the counter leak has not yet been proven; the stale 3/3 state itself was directly verified.

### Repair and verification required

- Make plugin copying noninteractive and idempotent, with success when destination files already exist. Evaluate an upstream chart fix or a controlled chart patch; `cp --update=none` is a candidate that must be checked against the controller image.
- Reconcile stale Jenkins agent records and provisioning counts during recovery. Validate stable static template IDs and cleanup of restored dynamic templates.
- Keep the global agent cap at 3; increasing the cap would hide the accounting error and defeat the cluster's resource limit.
- Document an ordered recovery procedure covering stalled warm-up builds, stale Jenkins nodes, failed agent pods, and controller recreation. The full proposed clean-agent restart procedure has not yet been verified end to end.
- Add a regression check for controller restart with existing plugin files, plus a test VM snapshot restore check.

### Acceptance criteria

- Controller initialization completes after restart and snapshot restore, including when plugin files already exist.
- The provisioner's recorded count agrees with actual registered agents; with zero nodes, the count is zero.
- Warm-up runs provision and connect one agent from each class: `lab-ci-runner`, `lab-ci-light`, and `lab-cd-runner-dev`.
- All three warm-up jobs finish successfully while the global cap remains 3.
- `make jenkins-up` and the post-restore validation pass without manually resetting counters.
