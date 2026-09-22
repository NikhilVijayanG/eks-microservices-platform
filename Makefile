.DEFAULT_GOAL := help
SHELL := /bin/bash

ENV      ?= dev
PROJECT  ?= msplatform
REGION   ?= us-east-1
TF_DIR    = terraform/envs/$(ENV)
SERVICES  = products orders gateway
ACCOUNT   = $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
REGISTRY  = $(ACCOUNT).dkr.ecr.$(REGION).amazonaws.com
TAG      ?= sha-$(shell git rev-parse --short=12 HEAD 2>/dev/null || echo local)

# Backend config comes from the bootstrap outputs
TF_BACKEND = -backend-config="bucket=$(PROJECT)-tfstate-$(ACCOUNT)" \
             -backend-config="dynamodb_table=$(PROJECT)-tflock" \
             -backend-config="region=$(REGION)"

.PHONY: help bootstrap init plan apply destroy outputs kubeconfig \
        validate fmt lint test build push render deploy rollout smoke \
        grafana prometheus alertmanager clean

help: ## Show targets
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ------------------------------------------------------------------ terraform
bootstrap: ## One-time: state bucket, lock table, GitHub OIDC role (needs GITHUB_REPO=owner/name)
	cd terraform/bootstrap && terraform init && terraform apply -var="github_repo=$(GITHUB_REPO)" -var="project=$(PROJECT)" -var="region=$(REGION)"

init: ## terraform init for ENV
	cd $(TF_DIR) && terraform init -input=false -reconfigure $(TF_BACKEND)

plan: init ## terraform plan for ENV
	cd $(TF_DIR) && terraform plan -input=false -out=tfplan

apply: init ## terraform apply for ENV (creates the whole platform, ~20 min)
	cd $(TF_DIR) && terraform apply -input=false

destroy: init ## Tear down ENV (deletes the cluster!)
	kubectl delete ingress --all -n microservices --ignore-not-found || true
	cd $(TF_DIR) && terraform destroy

outputs: ## Show terraform outputs
	cd $(TF_DIR) && terraform output

kubeconfig: ## Point kubectl at the ENV cluster
	aws eks update-kubeconfig --region $(REGION) --name $(PROJECT)-$(ENV)

# ------------------------------------------------------------------ quality
fmt: ## terraform fmt
	terraform fmt -recursive terraform/

validate: ## Validate everything offline: terraform, kustomize, kubeconform (if installed)
	terraform fmt -recursive -check terraform/
	@for d in terraform/bootstrap terraform/envs/dev terraform/envs/prod; do \
	  echo "== $$d"; (cd $$d && terraform init -backend=false -input=false >/dev/null && terraform validate) || exit 1; done
	@for e in dev prod; do echo "== kustomize $$e"; kubectl kustomize kubernetes/overlays/$$e > /tmp/k-$$e.yaml || exit 1; \
	  command -v kubeconform >/dev/null && kubeconform -strict -summary -schema-location default \
	    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' /tmp/k-$$e.yaml || true; done

test: ## Run unit tests for all services
	@for s in $(SERVICES); do echo "== $$s"; (cd services/$$s && npm ci --silent && npm test) || exit 1; done

# ------------------------------------------------------------------ images
build: ## Build all service images locally
	@for s in $(SERVICES); do docker build -f services/Dockerfile --build-arg SERVICE=$$s --build-arg APP_VERSION=$(TAG) -t $(PROJECT)/$$s:$(TAG) services; done

push: build ## Build and push to ECR with TAG
	aws ecr get-login-password --region $(REGION) | docker login --username AWS --password-stdin $(REGISTRY)
	@for s in $(SERVICES); do docker tag $(PROJECT)/$$s:$(TAG) $(REGISTRY)/$(PROJECT)/$$s:$(TAG) && docker push $(REGISTRY)/$(PROJECT)/$$s:$(TAG); done

# ------------------------------------------------------------------ deploy
render: ## Render manifests for ENV with TAG (requires kustomize binary)
	@cd kubernetes/overlays/$(ENV) && for s in $(SERVICES); do kustomize edit set image $$s=$(REGISTRY)/$(PROJECT)/$$s:$(TAG); done && kustomize build .

deploy: ## Apply manifests for ENV with TAG and wait for rollout
	$(MAKE) render | kubectl apply --server-side --force-conflicts -f -
	$(MAKE) rollout

rollout: ## Wait for all deployments
	@for s in $(SERVICES); do kubectl -n microservices rollout status deploy/$$s --timeout=5m || exit 1; done

smoke: ## Hit the gateway through the ALB
	@host=$$(kubectl -n microservices get ingress gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'); \
	 echo "Gateway: http://$$host"; curl -fsS http://$$host/api/products | head -c 300; echo; \
	 curl -fsS -X POST http://$$host/api/orders -H 'content-type: application/json' -d '{"productId":"p-100","quantity":2}'; echo

# ------------------------------------------------------------------ observability
grafana: ## Port-forward Grafana to :3000 and print the admin password
	@aws secretsmanager get-secret-value --secret-id $(PROJECT)-$(ENV)/grafana-admin --query SecretString --output text
	kubectl -n monitoring port-forward svc/kps-grafana 3000:80

prometheus: ## Port-forward Prometheus to :9090
	kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090

alertmanager: ## Port-forward Alertmanager to :9093
	kubectl -n monitoring port-forward svc/kps-alertmanager 9093:9093

clean: ## Remove local build artefacts
	find . -name ".terraform" -type d -prune -exec rm -rf {} + ; rm -f terraform/envs/*/tfplan terraform/envs/*/plan.txt
