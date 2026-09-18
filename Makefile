.DEFAULT_GOAL := help
BACKEND := backend
CORE := client/Packages/TraccioCore
COUNTRY ?= IT
CERTS := $(BACKEND)/.certs

help: ## Show the available commands
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

setup: ## Install backend and client dependencies
	cd $(BACKEND) && uv venv && uv sync
	cd $(CORE) && swift package resolve

reset-venv: ## Recreate the backend's venv from scratch (fixes import errors)
	cd $(BACKEND) && rm -rf .venv && uv venv && uv sync

run: db-upgrade ## Run the backend locally with reload
	cd $(BACKEND) && uv run uvicorn traccio.api.main:app --reload

run-tls: db-upgrade ## Run the backend over local https (self-signed cert) for the OB callback
	@mkdir -p $(CERTS)
	@test -f $(CERTS)/cert.pem || openssl req -x509 -newkey rsa:2048 -nodes \
		-keyout $(CERTS)/key.pem -out $(CERTS)/cert.pem -days 365 -subj "/CN=localhost"
	cd $(BACKEND) && uv run uvicorn traccio.api.main:app --reload \
		--ssl-keyfile .certs/key.pem --ssl-certfile .certs/cert.pem

eb-aspsps: ## List Enable Banking ASPSPs for a country (COUNTRY=IT), validates auth
	cd $(BACKEND) && uv run python scripts/eb_smoke.py --country $(COUNTRY)

eb-connections: ## List the dev user's connections (id, provider, status)
	cd $(BACKEND) && uv run python scripts/eb_field_census.py --list

CONNECTION ?=
eb-census: ## Census a connection's transaction fields (presence only, never values)
	cd $(BACKEND) && uv run python scripts/eb_field_census.py --connection-id $(CONNECTION) $(CENSUS_ARGS)

APPLY ?=
repair-empty-fields: ## Repair a connection's empty booked_at/value_date/description (APPLY=1 to write, else dry-run)
	cd $(BACKEND) && uv run python scripts/repair_empty_transaction_fields.py \
		--connection-id $(CONNECTION) $(if $(filter 1,$(APPLY)),--apply,) $(REPAIR_ARGS)

test: test-backend test-core ## Run every test suite

test-backend: ## Run the Python backend tests
	cd $(BACKEND) && uv run pytest

test-core: ## Run the Swift package tests
	cd $(CORE) && swift test

test-app: xcode ## Run the App/ target's tests (needs Xcode; not part of `make test`)
	cd client && xcodebuild -project Traccio.xcodeproj -scheme Traccio \
		-destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO

lint: ## Lint and type-check the backend
	cd $(BACKEND) && uv run ruff check . && uv run mypy src

fmt: ## Format and auto-fix the backend
	cd $(BACKEND) && uv run ruff format . && uv run ruff check --fix .

db-revision: ## Generate an Alembic migration via autogenerate (m="message")
	cd $(BACKEND) && uv run alembic revision --autogenerate -m "$(m)"

db-upgrade: ## Apply migrations up to head
	cd $(BACKEND) && uv run alembic upgrade head

seed-dev: db-upgrade ## Populate the DB with the dev user and a few synthetic accounts
	cd $(BACKEND) && uv run python -m traccio.db.seed_dev

xcode: ## Regenerate the Xcode project from Project.yml
	cd client && xcodegen generate

icon: ## Regenerate the app icon and launch mark from the tokens (scripts/gen-app-icon.swift)
	swift scripts/gen-app-icon.swift

openapi: ## Export the OpenAPI schema to docs/api/openapi.json
	cd $(BACKEND) && uv run python -m traccio.api.export_openapi ../docs/api/openapi.json

.PHONY: help setup reset-venv run run-tls eb-aspsps eb-connections eb-census repair-empty-fields test test-backend test-core test-app lint fmt db-revision db-upgrade seed-dev xcode icon openapi