.PHONY: help verify update

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

verify: ## Validate skills.yaml and confirm every referenced ref exists
	@bash scripts/verify.sh

update: ## Reconcile submodules to skills.yaml and commit any changes
	@bash scripts/update.sh
