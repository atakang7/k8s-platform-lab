# Bugs

Bugs found while running the full runbook in a fresh test VM
([test/README.md](../test/README.md)), and how each was found and fixed.

## How they were found

~~~text
17 full runs from scratch (make test-vm)
            │
            ▼
a run fails or needs its retry
            │
            ▼
read the error word by word
            │
            ▼
one hypothesis
            │
            ▼
prove it with a read-only command
            │
            ▼
fix the cause ──► rerun
~~~

~~~text
runs 1–5    4 pass, 3 needed the retry, 1 fail
runs 6–16   PR #96 merged: 11 pass, 4 needed the retry
run 17      PR #97 merged: pass, no retry
~~~

The platform never broke in any run. Every late failure was a check
misreading a healthy system.

## Summary

| # | Bug | Status |
| --- | --- | --- |
| 1 | `\| grep -q` and `\| head` under pipefail report false failures | fixed |
| 2 | node-2 drops SSH during edge validation | fixed |
| 3 | node-2 runs out of memory | fixed |
| 4 | Grafana cannot be scheduled on node-3 | fixed |
| 5 | Ansible picks a Python that does not exist | fixed |
| 6 | Ansible fails to start over SSH (locale) | fixed |
| 7 | A rerun skips Ansible on existing VMs | fixed |
| 8 | Snapshot restore looks for a deleted CD | fixed |
| 9 | A rerun breaks the running test VM's disk | fixed |
| 10 | A full host disk freezes the test VM | fixed |
| 11 | Grafana restarts on every rerun | open |
| 12 | Grafana is killed during its first start | open |

---

## 1. False failures from `| grep -q` and `| head`

**Symptom:** run 5 failed with `FAIL | DNS read policy is absent`.

**Detected by:** reading the policy right after the run. It was there.

~~~bash
vault policy read dns-read      # path "secret/data/edge/dns/tsig" { … }
~~~

**Cause:** the check failed because `grep -q` exits as soon as it finds its
line. If `vault` is still writing, the kernel kills it with SIGPIPE, and
`pipefail` turns that into a failed line.

~~~bash
set -Eeuo pipefail
vault policy read dns-read | grep -q 'secret/data/edge/dns/tsig' ||
  fail 'DNS read policy is absent'
~~~

The log shows no Vault error, so Vault itself did not fail; it was killed
silently. Reproduced with a writer that pauses mid-output:

~~~text
FAIL | DNS read policy is absent   (exit codes: 141 0)
~~~

`141` is the writer killed by SIGPIPE. `0` is `grep`, which found the line.

**Fix:** save the output first, then match it.

~~~bash
dns_policy="$(vault policy read dns-read)"
[[ "${dns_policy}" == *secret/data/edge/dns/tsig* ]] ||
  fail 'DNS read policy is absent'
~~~

A repository-wide scan found three more of the same bug:

| File | Risk |
| --- | --- |
| `infra/bin/prerequisites` | silently skipped turning off the VirtualBox DHCP server |
| `delivery/jenkins/build-ci-agent.sh` | the agent image build could fail |
| `delivery/pipeline/resources/lab/delivery/publish-chart.sh` | the chart publish could fail |

**Commits:** `d3f2e84` (PR #96), `4bfc4fb` (PR #98).

---

## 2. node-2 drops SSH during edge validation

**Symptom:** `FAIL | node-2 SSH is unavailable` in `make edge-validate`,
right after `make edge-up`. Seen in 6 of 16 runs; the retry always passed.

**Detected by:** the same check, always node-2, always at the same moment.
The log showed no SSH error at all.

**Cause:** the check failed because node-2 was busy starting the edge
workloads and dropped the SSH session. Two things hid and kept it:

- Vagrant's `ssh-config` sets `LogLevel FATAL`, so the SSH error was never
  printed.
- The first fix added `ConnectionAttempts`, which only retries opening the
  TCP connection, not a session dropped after it.

**Fix:** retry the whole SSH command for up to a minute, and print why it
failed.

~~~bash
for _ in {1..6}; do
  if addresses="$(ssh -F "${ssh_config}" -o LogLevel=ERROR -o ConnectTimeout=10 \
    "node-${node}" 'ip -o -4 addr show')"; then
    break
  fi
  sleep 10
done
~~~

Ansible got the same patience in `infra/ansible/ansible.cfg`: `timeout = 60`
and `retries = 3`.

**Commits:** `493c958` (PR #96), `5f37264` (PR #97). Run 17 passed without
the retry.

---

## 3. node-2 runs out of memory

**Symptom:** `node-2 SSH is unavailable`, and Fluent Bit `Available: 2/3`
until Helm rolled the release back.

**Detected by:**

~~~text
node-2   memory available: 47 MB of 1971 MB    load average: 31 (2 CPUs)
~~~

**Cause:** node-2 thrashed because 2 GiB cannot hold ingress, MetalLB,
Prometheus and Fluent Bit. With no free memory and no swap, Linux kept
dropping program files from memory and reading them back from disk.

**Fix:** node-2 gets 4 GiB in the `Vagrantfile`, the one place node memory
is set. The test VM gets 13 GiB to hold the 10 GiB of nodes.

**Commit:** `a73cc9a` (PR #101).

---

## 4. Grafana cannot be scheduled on node-3

**Symptom:** `observability-up` failed with `Progress deadline exceeded` for
Grafana and the Prometheus operator.

**Detected by:**

~~~text
FailedScheduling  0/3 nodes are available: 1 Insufficient memory
~~~

**Cause:** Grafana could not be placed because node-3 had been cut to 3 GiB
to give node-2 more. Jenkins and three CI build agents had reserved
(requested) almost all of it. The scheduler places pods by requests, not by
real usage.

**Fix:** node-3 stays at 4 GiB.

---

## 5. Ansible picks a Python that does not exist

**Symptom:** node-2 failed at `Gathering Facts`:

~~~text
/bin/sh: 1: /usr/bin/python: not found
~~~

**Detected by:** `ok=0 failed=1` for node-2 only, in `PLAY RECAP`.

**Cause:** Ansible chose `/usr/bin/python` because interpreter discovery
timed out on the busy node, and `interpreter_python = auto_silent` falls back
to that path quietly. Ubuntu 20.04 only has `python3`.

**Fix:** `interpreter_python = /usr/bin/python3` in `infra/ansible/ansible.cfg`.

**Commit:** `edb30d7`.

---

## 6. Ansible fails to start over SSH

**Symptom:**

~~~text
ERROR: Ansible could not initialize the preferred locale: unsupported locale setting
~~~

**Detected by:** comparing `locale` on the host (`LC_NUMERIC=tr_TR.UTF-8`)
with `locale -a` in the VM (no `tr_TR`).

**Cause:** Ansible refused to start because SSH forwards the host's locale
(`SendEnv LANG LC_*`) and the VM does not have it.

**Fix:** `test/bin/runbook` sets `LC_ALL=C.UTF-8`.

**Commit:** `14d7811`.

---

## 7. A rerun skips Ansible on existing VMs

**Symptom:** the second runbook attempt printed `Machine already provisioned`
for every node and failed the same way again.

**Cause:** the retry could not repair anything because plain `vagrant up`
only provisions new VMs.

**Fix:** `make cluster-up` runs `vagrant up --provision`, so Ansible
reconciles existing VMs too.

**Commit:** `23d3ac4`.

---

## 8. Snapshot restore looks for a deleted CD

**Symptom:**

~~~text
error: Cannot access storage file '/var/lib/libvirt/boot/virtinst-kxnv9pgz-cloudinit.iso'
~~~

**Detected by:** the file name (`virtinst`, `cloudinit`, random letters means
a temporary file from virt-install), then:

~~~bash
virsh domblklist lab-test                     # sda  -
virsh snapshot-dumpxml lab-test ready | grep cloudinit   # still there
~~~

**Cause:** restore failed because virt-install deletes its cloud-init CD
after the first boot and removes it from the saved config, but the running
VM keeps it attached. The snapshot recorded the running VM.

**Fix:** `test/bin/up` ejects the CD from the running VM once SSH is up.

~~~bash
virsh change-media lab-test sda --eject --live
~~~

**Commit:** `14d7811`.

---

## 9. A rerun breaks the running test VM's disk

**Symptom:** apt inside the test VM failed with `Input/output error`.

**Detected by:** the Ubuntu image was 318 MB of 596 MB.

**Cause:** the VM's disk broke because a rerun of `test/bin/up` downloaded
the Ubuntu image over the file the running VM's disk reads from, and the
download was stopped halfway.

**Fix:** `test/bin/up` is idempotent. Each step does only what is missing,
an existing image is never replaced, and a download lands in `.part` before
it is renamed.

**Commit:** `14d7811`.

---

## 10. A full host disk freezes the test VM

**Symptom:** `ssh: connect to host 192.168.150.10 port 22: No route to host`.

**Detected by:**

~~~bash
virsh domstate lab-test --reason   # paused (I/O error)
virsh domblkerror lab-test         # vda: no space
df -h /                                   # 100%
~~~

**Cause:** libvirt paused the VM because its thin disk grew until the host
disk was full.

**Fix:** the test VM disk is capped at 70 GiB, the README states the host
space it needs, and `test/bin/up` resumes a paused VM.

**Commit:** `14d7811`.

---

## 11. Grafana restarts on every rerun (open)

**Symptom:** every `make observability-up` replaced the Grafana pod.

**Detected by:** comparing the old and new ReplicaSet pod templates. Only one
annotation differed:

~~~text
checksum/secret: 905fe9a3…  →  2eaa45b3…
~~~

**Cause:** Grafana restarts because no admin password is set, so the chart
generates a new random one on every render. A new password changes the
Secret, its checksum, and so the pod. It also changes the admin password on
every run, which breaks idempotency.

**Planned fix:** create a `grafana-admin` Secret once, if missing, and point
`grafana.admin.existingSecret` at it.

---

## 12. Grafana is killed during its first start (open)

**Symptom:** `Deployment/observability/observability-grafana not ready …
Progress deadline exceeded`, and Helm uninstalled the whole release.

**Detected by:** the Grafana events:

~~~text
pulled image in 4m29s
Liveness probe failed: … connect: connection refused
Container grafana failed liveness probe, will be restarted
~~~

**Cause:** Grafana was restarted mid-start because it has no startup probe,
so the liveness probe judged it while it was still setting up its database.
`--rollback-on-failure` then uninstalled the whole release, because a first
install has no earlier version to return to.

**Planned fix:** a `startupProbe` for Grafana in
`platform/observability/kube-prometheus-stack/values.yaml`.
