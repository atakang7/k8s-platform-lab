# Test VM

Runs the full [RUNBOOK.md](../RUNBOOK.md) bring-up in a fresh KVM VM.

~~~text
make test-vm
     │
     ▼
lab-test (virsh)
     │  copy repo + .env
     ▼
test/bin/runbook ──fail──► run once more
     │
     ▼
make e2e-validate ──► PASS
~~~

## Host setup

Install KVM, libvirt and
[virt-install](https://github.com/virt-manager/virt-manager/blob/main/man/virt-install.rst#--cloud-init),
then log in again for the `libvirt` group. `bin/up` uses your
`~/.ssh/id_ed25519.pub` to log in to the VM.

~~~bash
sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst rsync
sudo usermod -aG libvirt "$USER"
~~~

VirtualBox runs inside the test VM, so turn on
[nested virtualization](https://docs.kernel.org/virt/kvm/x86/running-nested-guests.html#enabling-nested-x86).
On AMD, use `kvm_amd` instead of `kvm_intel`. Stop running VMs first:

~~~bash
echo 'options kvm_intel nested=1' | sudo tee /etc/modprobe.d/kvm-nested.conf
sudo modprobe -r kvm_intel
sudo modprobe kvm_intel
cat /sys/module/kvm_intel/parameters/nested    # Y
~~~

The test VM needs about 83 GiB free on the host: its disk grows up to
70 GiB, and a snapshot adds its 13 GiB of memory. Check with `df -h /`.

Fill in `.env` as [RUNBOOK.md §4](../RUNBOOK.md#4-ci-credentials) shows.

## Run

~~~bash
make test-vm
make test-vm-ssh   # log in to the VM
~~~

Start an existing VM without rerunning the runbook. This also starts its
network if inactive, and resumes the VM if paused:

~~~bash
make test-vm-start
~~~

## Browser

Opens Jenkins and Grafana with a real padlock:

~~~bash
make test-vm-browser
~~~

It uses its own Firefox profile, which trusts only the lab CA and reaches the
VM through an SSH SOCKS proxy that resolves names in the VM. Nothing else on
the host changes. Close Firefox to close the proxy. It needs `libnss3-tools`
for `certutil`.

## Snapshot

Save the VM once the runbook passes, and return to it before a demo. The
snapshot keeps memory too, so the restored system is already running.

~~~bash
make test-vm-snapshot          # save as "ready"
make test-vm-restore           # go back to "ready"
make test-vm-snapshot-delete   # delete "ready"
~~~

After a restore the VM clock jumps forward. Run `make e2e-validate` inside
the VM once before you present.

## Remove the VM

Removes the VM, its disk, its network and the Ubuntu image:

~~~bash
make test-vm-destroy
~~~
