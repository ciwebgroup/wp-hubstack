.PHONY: build run test lint format typecheck clean help

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-15s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build the Docker image
	docker-compose build

run: ## Run diagnostics on a container (requires CONTAINER and SITE_PATH)
	docker-compose run --rm wp-tuner $(CONTAINER) --site-path $(SITE_PATH)

autofix: ## Run diagnostics with auto-fix (requires CONTAINER and SITE_PATH)
	docker-compose run --rm wp-tuner $(CONTAINER) --site-path $(SITE_PATH) --auto-fix

dryrun: ## Preview changes without applying them (requires CONTAINER and SITE_PATH)
	docker-compose run --rm wp-tuner $(CONTAINER) --site-path $(SITE_PATH) --dry-run

typecheck: ## Run MyPy type checking
	docker-compose run --rm wp-tuner mypy /app/wp_tune.py

format: ## Format code with black and isort
	docker run --rm -v $(PWD):/app -w /app python:3.11-slim sh -c "pip install black isort && black wp_tune.py && isort wp_tune.py"

lint: ## Run pylint
	docker-compose run --rm wp-tuner pylint /app/wp_tune.py

test: ## Run tests (when implemented)
	@echo "Tests not yet implemented"

clean: ## Clean up build artifacts
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete
	find . -type d -name ".mypy_cache" -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name ".pytest_cache" -exec rm -rf {} + 2>/dev/null || true

# Example usage:
# make build
# make run CONTAINER=wp_malibuheatingandair SITE_PATH=/var/opt/sites/malibuheatingandair.com
# make dryrun CONTAINER=wp_malibuheatingandair SITE_PATH=/var/opt/sites/malibuheatingandair.com
# make autofix CONTAINER=wp_malibuheatingandair SITE_PATH=/var/opt/sites/malibuheatingandair.com
