# Ansible must use the distro Python packages it was built against; a newer
# jinja2 in ~/.local breaks its templating (environmentfilter was removed).
export PYTHONNOUSERSITE := 1

.PHONY: prerequisites cluster-up cluster-validate container-validate validate edge-up edge-smoke edge-validate edge-down jenkins-up environment-up observability-up observability-smoke endpoints credentials policies-up policies-smoke vault-init vault-unseal e2e-validate destroy

prerequisites:
	./infra/bin/prerequisites

cluster-up:
	vagrant up

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

destroy:
	vagrant destroy
