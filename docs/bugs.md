# Bugs

Found by 17 full runs of the runbook in a fresh test VM ([test/README.md](../test/README.md)).
The platform never broke; every late failure was a check misreading a healthy system.

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
