# The linters run from pinned container images, so a laptop and the CI runner use
# the same versions. Needs docker, make, kubectl and helm; yamllint comes from pip.
# The cluster targets (deploy, e2e) use whatever kubectl context is current and
# install Vault in DEV MODE. Use a throwaway cluster, CI uses kind.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

K8S_VERSION  := 1.34.0
KUBECONFORM  := ghcr.io/yannh/kubeconform:v0.7.0-alpine
SHELLCHECK   := koalaman/shellcheck:v0.10.0
ACTIONLINT   := rhysd/actionlint:1.7.12
VAULT_CHART  := 0.34.1

# Built-in kinds come from the default location, External Secrets from a public catalog.
CRD_CATALOG := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json
CONFORM := docker run --rm -i $(KUBECONFORM) -strict -summary -kubernetes-version $(K8S_VERSION) \
	-schema-location default -schema-location '$(CRD_CATALOG)'
RUN := docker run --rm -v "$(CURDIR)":/mnt -w /mnt

.PHONY: help check lint yaml kubeconform shellcheck workflow-lint docker-test deploy deploy-db e2e e2e-db

help:
	@echo "check          lint + shellcheck + workflow-lint (no cluster needed)"
	@echo "docker-test    Vault dev + Postgres in plain Docker: bootstrap, policies, database engine"
	@echo "deploy         Vault (dev mode) + External Secrets + demo app into the current cluster"
	@echo "e2e            checks against that cluster"
	@echo "deploy-db      extension: Postgres and dynamic credentials"
	@echo "e2e-db         checks for the extension"

check: lint shellcheck workflow-lint

lint: yaml kubeconform

yaml:
	yamllint -s .

kubeconform:
	kubectl kustomize manifests/base | $(CONFORM) -
	kubectl kustomize manifests/dynamic-db | $(CONFORM) -
	helm template vault vault --repo https://helm.releases.hashicorp.com --version $(VAULT_CHART) \
		-f helm/vault-dev-values.yaml | $(CONFORM) -
	helm template vault vault --repo https://helm.releases.hashicorp.com --version $(VAULT_CHART) \
		-f helm/vault-raft-example-values.yaml | $(CONFORM) -

shellcheck:
	$(RUN) $(SHELLCHECK) -x scripts/*.sh tests/*.sh

workflow-lint:
	$(RUN) $(ACTIONLINT)

docker-test:
	tests/docker-vault.sh

deploy:
	scripts/deploy.sh

e2e:
	scripts/e2e.sh

deploy-db:
	scripts/deploy-db.sh

e2e-db:
	scripts/e2e-db.sh
