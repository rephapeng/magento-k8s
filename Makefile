# Convenience wrapper around the scripts. `make help` lists targets.
.DEFAULT_GOAL := help
NS ?= magento

.PHONY: help prereqs build deploy verify backup restore cleanup purge lint template logs pods

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

prereqs: ## Install ingress-nginx + metrics-server
	./scripts/install-prereqs.sh

build: ## Build custom Magento app + nginx images
	./scripts/build-images.sh

deploy: ## Deploy/upgrade the Helm release from .env
	./scripts/deploy.sh

verify: ## Run functional verification checks
	./scripts/verify.sh

backup: ## Backup DB + media to ./backups
	./scripts/backup.sh

restore: ## Restore from a backup dir: make restore SRC=backups/<ts>
	./scripts/restore.sh $(SRC)

cleanup: ## Uninstall release, keep PVCs
	./scripts/cleanup.sh

purge: ## Uninstall release AND delete PVCs + namespace
	./scripts/cleanup.sh --purge

lint: ## helm lint the chart
	helm lint charts/magento -f charts/magento/values.yaml --set secrets.dbPassword=x,secrets.dbRootPassword=x,secrets.adminPassword=x,secrets.cryptKey=x

template: ## Render manifests locally (dry-run)
	helm template magento charts/magento -f charts/magento/values.yaml \
	  --set secrets.dbPassword=x,secrets.dbRootPassword=x,secrets.adminPassword=x,secrets.cryptKey=x,secrets.cloudflareTunnelToken=x

pods: ## Watch pods
	kubectl -n $(NS) get pods -w

logs: ## Tail install job logs
	kubectl -n $(NS) logs -f job -l component=install
