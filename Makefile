# ===========================================================================
#  Centralized Observability Platform - task runner
#
#  Local flow :  make up -> make local-apply -> make kubeconfig -> make deploy
#                -> make workload -> make smoke
#  Cloud flow :  make gcp-init -> make gcp-apply -> make gcp-kubeconfig
#                -> make deploy -> make workload
# ===========================================================================

SHELL              := /bin/bash
.DEFAULT_GOAL      := help
.ONESHELL:

# --- Paths -----------------------------------------------------------------
ROOT_DIR           := $(shell pwd)
TF_LOCAL           := $(ROOT_DIR)/terraform/environments/local
TF_GCP             := $(ROOT_DIR)/terraform/environments/gcp
ANSIBLE_DIR        := $(ROOT_DIR)/ansible
KUBECONFIG_FILE    ?= $(ROOT_DIR)/.floci/kubeconfig

# --- Emulator --------------------------------------------------------------
EMULATOR_URL       ?= http://localhost:4588
HEALTH_URL         := $(EMULATOR_URL)/_floci-gcp/health

# --- Terraform -------------------------------------------------------------
# -parallelism=1 is mandatory. Both the emulator's IAM policy store and real
# GCP's google_project_iam_member use read-modify-write on a single project
# policy document; concurrent writes drop bindings silently.
TF_PARALLELISM     ?= 1
TF_APPLY_FLAGS     := -auto-approve -parallelism=$(TF_PARALLELISM)
TF_DESTROY_FLAGS   := -auto-approve -parallelism=$(TF_PARALLELISM)

# Fake OAuth token: floci-gcp does not cryptographically validate credentials,
# but the Google provider refuses to start without *some* credential source.
export GOOGLE_OAUTH_ACCESS_TOKEN ?= floci-mock-access-token

export ANSIBLE_CONFIG := $(ANSIBLE_DIR)/ansible.cfg

# ---------------------------------------------------------------------------
.PHONY: help
help: ## Show this help
	@echo ""
	@echo "  Centralized Observability Platform"
	@echo "  ----------------------------------"
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ===========================  LOCAL : EMULATOR  =============================
.PHONY: up
up: ## Start the floci-gcp emulator and wait until it is healthy
	@mkdir -p $(ROOT_DIR)/.floci/data
	docker compose up -d
	@$(ROOT_DIR)/scripts/wait-for-emulator.sh "$(EMULATOR_URL)"

.PHONY: down
down: ## Stop the emulator (keeps ./.floci/data)
	docker compose down

.PHONY: nuke
nuke: ## Stop the emulator, delete its state AND any spawned k3s sidecars
	-docker compose down -v
	-docker ps -aq --filter "name=obs-" | xargs -r docker rm -f
	-rm -rf $(ROOT_DIR)/.floci
	-rm -f $(KUBECONFIG_FILE)

.PHONY: health
health: ## Curl the emulator health endpoint
	curl -fsS $(HEALTH_URL) && echo "" || (echo "emulator not healthy"; exit 1)

# ===========================  LOCAL : TERRAFORM  ============================
.PHONY: local-init
local-init: ## terraform init for the local environment
	terraform -chdir=$(TF_LOCAL) init -upgrade

.PHONY: local-plan
local-plan: ## terraform plan against the emulator
	terraform -chdir=$(TF_LOCAL) plan -parallelism=$(TF_PARALLELISM)

.PHONY: local-apply
local-apply: up ## Provision VPC + IAM + GKE inside the emulator
	terraform -chdir=$(TF_LOCAL) init -input=false
	terraform -chdir=$(TF_LOCAL) apply $(TF_APPLY_FLAGS)

.PHONY: local-destroy
local-destroy: ## Destroy the locally emulated infrastructure
	terraform -chdir=$(TF_LOCAL) destroy $(TF_DESTROY_FLAGS)

.PHONY: local-output
local-output: ## Show local terraform outputs
	terraform -chdir=$(TF_LOCAL) output

.PHONY: kubeconfig
kubeconfig: ## Write the emulated GKE kubeconfig to .floci/kubeconfig
	@mkdir -p $(dir $(KUBECONFIG_FILE))
	terraform -chdir=$(TF_LOCAL) output -raw kubeconfig > $(KUBECONFIG_FILE)
	@chmod 600 $(KUBECONFIG_FILE)
	@echo "KUBECONFIG=$(KUBECONFIG_FILE)"
	@KUBECONFIG=$(KUBECONFIG_FILE) kubectl get nodes

# ============================  GCP : TERRAFORM  =============================
.PHONY: gcp-init
gcp-init: ## terraform init for real GCP (remote GCS backend)
	terraform -chdir=$(TF_GCP) init -upgrade

.PHONY: gcp-plan
gcp-plan: ## terraform plan against real GCP
	terraform -chdir=$(TF_GCP) plan -parallelism=$(TF_PARALLELISM)

.PHONY: gcp-apply
gcp-apply: ## Provision the real GCP infrastructure
	terraform -chdir=$(TF_GCP) apply $(TF_APPLY_FLAGS)

.PHONY: gcp-destroy
gcp-destroy: ## Destroy the real GCP infrastructure
	terraform -chdir=$(TF_GCP) destroy $(TF_DESTROY_FLAGS)

.PHONY: gcp-kubeconfig
gcp-kubeconfig: ## Fetch real GKE credentials via gcloud
	gcloud container clusters get-credentials \
	  $$(terraform -chdir=$(TF_GCP) output -raw cluster_name) \
	  --region $$(terraform -chdir=$(TF_GCP) output -raw region) \
	  --project $$(terraform -chdir=$(TF_GCP) output -raw project_id)

# ==============================  ANSIBLE  ===================================
.PHONY: galaxy
galaxy: ## Install the Ansible collections (kubernetes.core, community.general)
	ansible-galaxy install -r $(ANSIBLE_DIR)/requirements.yml

.PHONY: deploy
deploy: galaxy ## Namespaces + Secrets + RBAC + ELK + Prometheus/Grafana
	KUBECONFIG=$(KUBECONFIG_FILE) ansible-playbook \
	  -i $(ANSIBLE_DIR)/inventory/hosts.ini \
	  $(ANSIBLE_DIR)/playbook.yml \
	  -e kubeconfig_path=$(KUBECONFIG_FILE)

.PHONY: deploy-logging
deploy-logging: galaxy ## Deploy only the ELK logging pipeline
	KUBECONFIG=$(KUBECONFIG_FILE) ansible-playbook \
	  -i $(ANSIBLE_DIR)/inventory/hosts.ini \
	  $(ANSIBLE_DIR)/playbook.yml --tags logging \
	  -e kubeconfig_path=$(KUBECONFIG_FILE)

.PHONY: deploy-monitoring
deploy-monitoring: galaxy ## Deploy only the Prometheus/Grafana metrics pipeline
	KUBECONFIG=$(KUBECONFIG_FILE) ansible-playbook \
	  -i $(ANSIBLE_DIR)/inventory/hosts.ini \
	  $(ANSIBLE_DIR)/playbook.yml --tags monitoring \
	  -e kubeconfig_path=$(KUBECONFIG_FILE)

.PHONY: check
check: galaxy ## Dry-run the playbook (--check --diff)
	KUBECONFIG=$(KUBECONFIG_FILE) ansible-playbook \
	  -i $(ANSIBLE_DIR)/inventory/hosts.ini \
	  $(ANSIBLE_DIR)/playbook.yml --check --diff \
	  -e kubeconfig_path=$(KUBECONFIG_FILE)

# ==============================  WORKLOAD  ==================================
.PHONY: workload
workload: ## Deploy the NGINX test workload + 200/404 load generator
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl apply -f $(ROOT_DIR)/workloads/test-app.yaml
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl -n workload rollout status deploy/nginx-demo --timeout=180s

.PHONY: smoke
smoke: ## End-to-end verification of both pipelines
	KUBECONFIG=$(KUBECONFIG_FILE) $(ROOT_DIR)/scripts/smoke-test.sh

# ===============================  ACCESS  ===================================
.PHONY: kibana
kibana: ## Port-forward Kibana to http://localhost:5601
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl -n logging port-forward svc/kibana-kibana 5601:5601

.PHONY: grafana
grafana: ## Port-forward Grafana to http://localhost:3000
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

.PHONY: prometheus
prometheus: ## Port-forward Prometheus to http://localhost:9090
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090

.PHONY: elasticsearch
elasticsearch: ## Port-forward Elasticsearch to http://localhost:9200
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl -n logging port-forward svc/elasticsearch-master 9200:9200

.PHONY: pods
pods: ## Show pods in all three namespaces
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pods -n logging -n monitoring 2>/dev/null || true
	KUBECONFIG=$(KUBECONFIG_FILE) kubectl get pods -A \
	  --field-selector metadata.namespace!=kube-system

# ===============================  LIFECYCLE  ================================
.PHONY: all
all: up local-apply kubeconfig deploy workload smoke ## Full local bring-up

.PHONY: clean
clean: local-destroy nuke ## Tear everything down
