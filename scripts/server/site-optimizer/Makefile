.PHONY: help build run shell test lint type-check format clean

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: ## Build Docker image
	docker-compose build

run: ## Run CLI (pass ARGS="command" to run specific command)
	docker-compose run --rm site-optimizer $(ARGS)

shell: ## Open shell in container
	docker-compose run --rm site-optimizer sh

test: ## Run tests
	docker-compose run --rm site-optimizer sh -c "pytest -v"

test-cov: ## Run tests with coverage
	docker-compose run --rm site-optimizer sh -c "pytest --cov=src --cov-report=term-missing --cov-report=html"

lint: ## Run linter (ruff)
	docker-compose run --rm site-optimizer sh -c "ruff check src/"

type-check: ## Run type checker (mypy)
	docker-compose run --rm site-optimizer sh -c "mypy src/"

format: ## Format code with black
	docker-compose run --rm site-optimizer sh -c "black src/ tests/"

format-check: ## Check code formatting
	docker-compose run --rm site-optimizer sh -c "black --check src/ tests/"

check-all: format-check lint type-check test ## Run all checks

clean: ## Clean up generated files
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .mypy_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete
	rm -rf htmlcov/ .coverage

# Development commands
dev-install: ## Install development dependencies locally
	pip install -r requirements.txt -r requirements-dev.txt

# Example usage commands
example-help: ## Show CLI help
	docker-compose run --rm site-optimizer --help

example-inventory: ## Show inventory commands
	docker-compose run --rm site-optimizer inventory --help

example-analyze: ## Show analyze commands
	docker-compose run --rm site-optimizer analyze --help

example-classify: ## Show classify commands
	docker-compose run --rm site-optimizer classify --help

example-plan: ## Show plan commands
	docker-compose run --rm site-optimizer plan --help

example-deploy: ## Show deploy commands
	docker-compose run --rm site-optimizer deploy --help
