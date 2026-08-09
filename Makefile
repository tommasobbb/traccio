.DEFAULT_GOAL := help
BACKEND := backend
CORE := client/Packages/TraccioCore

help: ## Mostra i comandi disponibili
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

setup: ## Installa le dipendenze di backend e client
	cd $(BACKEND) && uv venv && uv sync
	cd $(CORE) && swift package resolve

reset-venv: ## Ricrea da zero il venv del backend (fix per import errors)
	cd $(BACKEND) && rm -rf .venv && uv venv && uv sync
	
run: ## Avvia il backend in locale con reload
	cd $(BACKEND) && uv run uvicorn traccio.api.main:app --reload

test: test-backend test-core ## Esegue tutti i test

test-backend: ## Test del backend Python
	cd $(BACKEND) && uv run pytest

test-core: ## Test del package Swift
	cd $(CORE) && swift test

lint: ## Lint e type check del backend
	cd $(BACKEND) && uv run ruff check . && uv run mypy src

fmt: ## Formatta e autocorregge il backend
	cd $(BACKEND) && uv run ruff format . && uv run ruff check --fix .

db-revision: ## Genera una migrazione Alembic da autogenerate (m="messaggio")
	cd $(BACKEND) && uv run alembic revision --autogenerate -m "$(m)"

db-upgrade: ## Applica le migrazioni fino a head
	cd $(BACKEND) && uv run alembic upgrade head

seed-dev: ## Popola il DB con l'utente dev e alcuni account sintetici
	cd $(BACKEND) && uv run python -m traccio.db.seed_dev

xcode: ## Rigenera il progetto Xcode da Project.yml
	cd client && xcodegen generate

openapi: ## Esporta lo schema OpenAPI in docs/api/openapi.json
	cd $(BACKEND) && uv run python -m traccio.api.export_openapi > ../docs/api/openapi.json

.PHONY: help setup reset-venv run test test-backend test-core lint fmt db-revision db-upgrade seed-dev xcode openapi