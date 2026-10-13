# Ansible must use the distro Python packages it was built against; a newer
# jinja2 in ~/.local breaks its templating (environmentfilter was removed).
export PYTHONNOUSERSITE := 1

.PHONY: prerequisites cluster-up cluster-validate container-validate validate edge-up edge-smoke edge-validate edge-down jenkins-up environment-up observability-up observability-smoke endpoints credentials policies-up policies-smoke vault-init vault-unseal e2e-validate test-vm test-vm-start test-vm-ssh test-vm-browser test-vm-snapshot test-vm-restore test-vm-snapshot-delete test-vm-destroy destroy

prerequisites:
	./infra/bin/prerequisites

# --provision reruns Ansible on VMs that already exist, so this reconciles.
cluster-up:
	vagrant up --provision

cluster-validate:
	./validation/cluster/validate.sh

container-validate:
	./validation/container/validate.sh

validate: cluster-validate container-validate

edge-up:
	./infra/edge/bin/up

edge-smoke:
	./validation/edge/smoke.sh

edge-validate:
	./validation/edge/validate.sh

edge-down:
	./infra/edge/bin/down

jenkins-up:
	./platform/jenkins/bin/up

environment-up:
	./platform/environment/bin/up

observability-up:
	./platform/observability/bin/up

observability-smoke:
	./platform/observability/bin/smoke

endpoints:
	@bash ./platform/bin/endpoints

credentials:
	@bash ./platform/bin/credentials

policies-up:
	./policies/bin/up

policies-smoke:
	./policies/bin/smoke

vault-init:
	./infra/edge/bin/vault-init

vault-unseal:
	./infra/edge/bin/vault-unseal

e2e-validate:
	./validation/e2e/validate.sh

test-vm:
	./test/bin/up

test-vm-start:
	./test/bin/up --start-only

test-vm-ssh:
	ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR ubuntu@192.168.150.10

test-vm-browser:
	./test/bin/browser

test-vm-snapshot:
	virsh -c qemu:///system snapshot-create-as lab-test ready

test-vm-restore:
	virsh -c qemu:///system snapshot-revert lab-test ready --running

test-vm-snapshot-delete:
	virsh -c qemu:///system snapshot-delete lab-test ready

test-vm-destroy:
	-virsh -c qemu:///system destroy lab-test
	-virsh -c qemu:///system undefine lab-test --remove-all-storage --snapshots-metadata
	-virsh -c qemu:///system net-destroy lab-test
	-virsh -c qemu:///system net-undefine lab-test
	-virsh -c qemu:///system vol-delete --pool default ubuntu-24.04-server-cloudimg-amd64.img

destroy:
	vagrant destroy
