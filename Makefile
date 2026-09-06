.DEFAULT_GOAL := help
BACKEND := backend
CORE := client/Packages/TraccioCore
COUNTRY ?= IT
CERTS := $(BACKEND)/.certs

help: ## Mostra i comandi disponibili
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

setup: ## Installa le dipendenze di backend e client
	cd $(BACKEND) && uv venv && uv sync
	cd $(CORE) && swift package resolve

reset-venv: ## Ricrea da zero il venv del backend (fix per import errors)
	cd $(BACKEND) && rm -rf .venv && uv venv && uv sync
	
run: db-upgrade ## Avvia il backend in locale con reload
	cd $(BACKEND) && uv run uvicorn traccio.api.main:app --reload

run-tls: db-upgrade ## Avvia il backend in https locale (cert self-signed) per il callback OB
	@mkdir -p $(CERTS)
	@test -f $(CERTS)/cert.pem || openssl req -x509 -newkey rsa:2048 -nodes \
		-keyout $(CERTS)/key.pem -out $(CERTS)/cert.pem -days 365 -subj "/CN=localhost"
	cd $(BACKEND) && uv run uvicorn traccio.api.main:app --reload \
		--ssl-keyfile .certs/key.pem --ssl-certfile .certs/cert.pem

eb-aspsps: ## Elenca gli ASPSP Enable Banking per un paese (COUNTRY=IT), valida l'auth
	cd $(BACKEND) && uv run python scripts/eb_smoke.py --country $(COUNTRY)

eb-connections: ## Elenca le connessioni dell'utente dev (id, provider, stato)
	cd $(BACKEND) && uv run python scripts/eb_field_census.py --list

CONNECTION ?=
eb-census: ## Censisce i campi (solo presenza, mai valori) delle transazioni di una connessione
	cd $(BACKEND) && uv run python scripts/eb_field_census.py --connection-id $(CONNECTION) $(CENSUS_ARGS)

APPLY ?=
repair-empty-fields: ## Ripara booked_at/value_date/description vuoti di una connessione (APPLY=1 per scrivere, altrimenti dry-run)
	cd $(BACKEND) && uv run python scripts/repair_empty_transaction_fields.py \
		--connection-id $(CONNECTION) $(if $(filter 1,$(APPLY)),--apply,) $(REPAIR_ARGS)

test: test-backend test-core ## Esegue tutti i test

test-backend: ## Test del backend Python
	cd $(BACKEND) && uv run pytest

test-core: ## Test del package Swift
	cd $(CORE) && swift test

test-app: xcode ## Test del target App/ (richiede Xcode; non incluso in `make test`)
	cd client && xcodebuild -project Traccio.xcodeproj -scheme Traccio \
		-destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO

lint: ## Lint e type check del backend
	cd $(BACKEND) && uv run ruff check . && uv run mypy src

fmt: ## Formatta e autocorregge il backend
	cd $(BACKEND) && uv run ruff format . && uv run ruff check --fix .

db-revision: ## Genera una migrazione Alembic da autogenerate (m="messaggio")
	cd $(BACKEND) && uv run alembic revision --autogenerate -m "$(m)"

db-upgrade: ## Applica le migrazioni fino a head
	cd $(BACKEND) && uv run alembic upgrade head

seed-dev: db-upgrade ## Popola il DB con l'utente dev e alcuni account sintetici
	cd $(BACKEND) && uv run python -m traccio.db.seed_dev

xcode: ## Rigenera il progetto Xcode da Project.yml
	cd client && xcodegen generate

icon: ## Rigenera l'icona app e il launch mark dai token (scripts/gen-app-icon.swift)
	swift scripts/gen-app-icon.swift

openapi: ## Esporta lo schema OpenAPI in docs/api/openapi.json
	cd $(BACKEND) && uv run python -m traccio.api.export_openapi ../docs/api/openapi.json

.PHONY: help setup reset-venv run run-tls eb-aspsps eb-connections eb-census repair-empty-fields test test-backend test-core test-app lint fmt db-revision db-upgrade seed-dev xcode icon openapi