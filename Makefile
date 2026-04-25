SHELL := /bin/bash

DOCKER ?= docker
GIT ?= git
KODEXLINK ?= kodexlink
NPM ?= npm
TAILSCALE ?= tailscale
MARKDOWNLINT ?= markdownlint
SHELLCHECK ?= shellcheck

ENV_FILE ?= $(HOME)/.config/kodexlink-tools/relay.env
COMPOSE_FILE ?= docker-compose.kodexlink-relay.yml
MARKDOWNLINT_CONFIG ?= $(HOME)/.markdownlint.json
DEFAULT_PUBLIC_URL ?= http://127.0.0.1:8787
PUBLIC_URL ?=
RELAY_UPSTREAM_URL ?= https://github.com/David699/codex-mobile-relay.git
RELAY_SOURCE_DIR ?= $(HOME)/.local/share/kodexlink-tools/codex-mobile-relay

MARKDOWN_FILES := README.md CHANGELOG.md LICENSE.md docs/*.md
SHELL_FILES := scripts/kodexlink-relay.sh scripts/tailscale-cli-launcher

.DEFAULT_GOAL := help

.PHONY: help check-deps require-kodexlink require-npm require-tailscale docker-start fetch-relay-source update-relay-source ensure-env configure-relay-source configure-url install install-all update enable disable install-relay install-tool-cli update-tool-cli install-tool install-tailscale-cli tailscale-serve tailscale-serve-off tailscale-funnel tailscale-funnel-off pair start stop restart status logs health measure print-url compose-config doctor doctor-relay doctor-tailscale doctor-mobile privacy-check lint check

help: ## Show available targets
	@awk 'BEGIN { FS = ":.*##" } /^[a-zA-Z_-]+:.*##/ { printf "  %-24s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

check-deps: ## Check common command dependencies
	@missing=0; \
	for cmd in "$(DOCKER)" "$(GIT)" curl; do \
		if ! command -v "$$cmd" >/dev/null 2>&1; then \
			echo "Missing required command: $$cmd"; \
			missing=1; \
		fi; \
	done; \
	for cmd in "$(KODEXLINK)" "$(NPM)" "$(TAILSCALE)" "$(MARKDOWNLINT)" "$(SHELLCHECK)"; do \
		if ! command -v "$$cmd" >/dev/null 2>&1; then \
			echo "Optional command not found yet: $$cmd"; \
		fi; \
	done; \
	exit "$$missing"

require-kodexlink: ## Require the KodexLink desktop CLI
	@command -v "$(KODEXLINK)" >/dev/null 2>&1 || { echo "Missing $(KODEXLINK). Install the KodexLink desktop CLI first."; exit 1; }

require-npm: ## Require npm for installing the KodexLink desktop CLI
	@command -v "$(NPM)" >/dev/null 2>&1 || { echo "Missing $(NPM). Install Node.js/npm first."; exit 1; }

require-tailscale: ## Require the Tailscale CLI
	@command -v "$(TAILSCALE)" >/dev/null 2>&1 || { echo "Missing $(TAILSCALE). Run: make install-tailscale-cli"; exit 1; }

docker-start: ## Start Docker Desktop if the daemon is not available
	@if "$(DOCKER)" info >/dev/null 2>&1; then \
		echo "Docker is running."; \
	else \
		echo "Starting Docker Desktop..."; \
		open -ga Docker; \
		for attempt in {1..60}; do \
			if "$(DOCKER)" info >/dev/null 2>&1; then \
				echo "Docker is ready."; \
				exit 0; \
			fi; \
			sleep 2; \
		done; \
		echo "Docker did not become ready within 120 seconds."; \
		exit 1; \
	fi

fetch-relay-source: ## Clone or update the upstream relay source
	@if [[ -d "$(RELAY_SOURCE_DIR)/.git" ]]; then \
		echo "Updating relay source in $(RELAY_SOURCE_DIR)"; \
		if [[ -n "$$("$(GIT)" -C "$(RELAY_SOURCE_DIR)" status --porcelain)" ]]; then \
			echo "Relay source has local changes; resolve them before updating: $(RELAY_SOURCE_DIR)"; \
			exit 1; \
		fi; \
		"$(GIT)" -C "$(RELAY_SOURCE_DIR)" fetch --all --prune; \
		"$(GIT)" -C "$(RELAY_SOURCE_DIR)" pull --ff-only; \
	elif [[ -e "$(RELAY_SOURCE_DIR)" ]]; then \
		echo "Relay source path exists but is not a git repository: $(RELAY_SOURCE_DIR)"; \
		exit 1; \
	else \
		mkdir -p "$$(dirname "$(RELAY_SOURCE_DIR)")"; \
		"$(GIT)" clone "$(RELAY_UPSTREAM_URL)" "$(RELAY_SOURCE_DIR)"; \
	fi

update-relay-source: fetch-relay-source ## Alias for refreshing the upstream relay source

ensure-env: ## Create the private relay env file if it is missing
	@if [[ -f "$(ENV_FILE)" ]]; then \
		echo "Relay env exists: $(ENV_FILE)"; \
	else \
		initial_url="$(if $(PUBLIC_URL),$(PUBLIC_URL),$(DEFAULT_PUBLIC_URL))"; \
		KODEXLINK_RELAY_REPO="$(RELAY_SOURCE_DIR)" ./scripts/kodexlink-relay.sh init-env "$$initial_url"; \
	fi

configure-relay-source: ensure-env ## Point relay.env at the managed upstream source checkout
	@./scripts/kodexlink-relay.sh set-relay-repo "$(RELAY_SOURCE_DIR)"

configure-url: ensure-env ## Prompt for or set the relay public HTTPS URL
	@public_url="$(PUBLIC_URL)"; \
	if [[ -z "$$public_url" ]]; then \
		read -r -p "Relay HTTPS URL, for example https://machine-name.tailnet-name.ts.net: " public_url; \
	fi; \
	if [[ -z "$$public_url" ]]; then \
		echo "No relay URL provided."; \
		exit 1; \
	fi; \
	./scripts/kodexlink-relay.sh set-public-url "$$public_url"

install: install-all ## Install and configure everything without enabling services

install-all: ## Install CLI launcher, upstream relay source, env, and desktop CLI
	@$(MAKE) install-tailscale-cli
	@$(MAKE) fetch-relay-source
	@$(MAKE) ensure-env
	@$(MAKE) configure-relay-source
	@$(MAKE) configure-url
	@$(MAKE) install-tool-cli
	@echo "Install complete. Services are configured but not enabled."
	@echo "Run 'make enable' to start Docker, Tailscale Serve, and the KodexLink LaunchAgent."

update: ## Update relay source and desktop CLI without deleting pairing data
	@$(MAKE) fetch-relay-source
	@$(MAKE) configure-relay-source
	@$(MAKE) update-tool-cli
	@$(MAKE) restart
	@$(MAKE) install-tool
	@echo "Update complete. Existing paired devices are preserved because Docker volumes and the relay URL were not reset."

enable: ## Enable all runtime services
	@$(MAKE) docker-start
	@$(MAKE) ensure-env
	@$(MAKE) start
	@$(MAKE) tailscale-serve
	@$(MAKE) install-tool
	@echo "Services enabled. Set the same HTTPS relay URL in the mobile app Custom Address, then run 'make pair'."

disable: ## Disable all runtime services without deleting data
	@./scripts/kodexlink-relay.sh desktop-service-stop || true
	@./scripts/kodexlink-relay.sh tailscale-serve-off || true
	@./scripts/kodexlink-relay.sh down || true

install-relay: ## Install and start the Docker relay stack
	@$(MAKE) docker-start
	@$(MAKE) fetch-relay-source
	@$(MAKE) ensure-env
	@$(MAKE) configure-relay-source
	@./scripts/kodexlink-relay.sh up

install-tool-cli: require-npm ## Install the KodexLink desktop CLI from npm if missing
	@if command -v "$(KODEXLINK)" >/dev/null 2>&1; then \
		"$(KODEXLINK)" --version 2>/dev/null || "$(KODEXLINK)" doctor 2>/dev/null || true; \
	else \
		"$(NPM)" install -g kodexlink; \
	fi

update-tool-cli: require-npm ## Update the KodexLink desktop CLI from npm
	@"$(NPM)" install -g kodexlink@latest

install-tool: ensure-env install-tool-cli require-kodexlink ## Install the KodexLink desktop LaunchAgent
	@./scripts/kodexlink-relay.sh desktop-service-install

install-tailscale-cli: ## Install or refresh /usr/local/bin/tailscale
	@sudo install -m 0755 scripts/tailscale-cli-launcher /usr/local/bin/tailscale
	@/usr/local/bin/tailscale version

tailscale-serve: ensure-env require-tailscale ## Publish the relay privately with Tailscale Serve
	@./scripts/kodexlink-relay.sh tailscale-serve

tailscale-serve-off: require-tailscale ## Disable the Tailscale Serve mapping
	@./scripts/kodexlink-relay.sh tailscale-serve-off

tailscale-funnel: ensure-env require-tailscale ## Publish the relay publicly with Tailscale Funnel
	@./scripts/kodexlink-relay.sh tailscale-funnel

tailscale-funnel-off: require-tailscale ## Disable the Tailscale Funnel mapping
	@./scripts/kodexlink-relay.sh tailscale-funnel-off

pair: ensure-env require-kodexlink ## Open the local QR pairing panel
	@./scripts/kodexlink-relay.sh desktop-pair

start: ## Start the Docker relay stack
	@$(MAKE) docker-start
	@./scripts/kodexlink-relay.sh up

stop: ## Stop the Docker relay stack
	@./scripts/kodexlink-relay.sh down

restart: ## Restart the Docker relay stack
	@$(MAKE) docker-start
	@./scripts/kodexlink-relay.sh restart

status: ## Show relay container status and desktop agent status
	@./scripts/kodexlink-relay.sh status
	@echo
	@./scripts/kodexlink-relay.sh desktop-status || true

logs: ## Follow compose logs, optionally SERVICE=relay
	@./scripts/kodexlink-relay.sh logs $(SERVICE)

health: ## Check local relay health
	@./scripts/kodexlink-relay.sh health

measure: ## Show one-shot Docker CPU and memory usage
	@./scripts/kodexlink-relay.sh measure

print-url: ## Print the configured relay public URL
	@./scripts/kodexlink-relay.sh public-url

compose-config: ensure-env ## Validate the Docker Compose configuration
	@KODEXLINK_TOOLS_DIR="$(CURDIR)" "$(DOCKER)" compose --env-file "$(ENV_FILE)" -f "$(COMPOSE_FILE)" config >/dev/null

doctor: doctor-relay doctor-tailscale doctor-mobile privacy-check ## Run setup diagnostics

doctor-relay: ensure-env compose-config ## Check relay configuration and local health
	@./scripts/kodexlink-relay.sh health >/dev/null
	@echo "Relay health endpoint is reachable on localhost."

doctor-tailscale: require-tailscale ## Check Tailscale CLI and Serve mapping
	@"$(TAILSCALE)" status >/dev/null
	@"$(TAILSCALE)" serve status >/dev/null
	@echo "Tailscale CLI and Serve status are available."

doctor-mobile: ensure-env ## Check mobile-facing relay URL basics
	@set -a; source "$(ENV_FILE)"; set +a; \
	case "$${KODEXLINK_RELAY_PUBLIC_BASE_URL:-}" in \
		https://*) echo "Mobile relay URL is configured as HTTPS."; ;; \
		*) echo "Mobile relay URL should be an HTTPS Tailscale Serve URL before pairing."; exit 1; ;; \
	esac; \
	curl -fsS "$${KODEXLINK_RELAY_PUBLIC_BASE_URL%/}/healthz" >/dev/null; \
	echo "Mobile-facing relay health endpoint is reachable."

privacy-check: ## Scan repository files for common generated secrets
	@pair_re="pair_""[0-9a-f-]{36}"; \
	secret_re="secret_""[0-9a-f-]{36}"; \
	node_re="node""key"; \
	auth_re="Auth""URL"; \
	ts_ips_re="Tailscale""IPs"; \
	allowed_ips_re="Allowed""IPs"; \
	path_re="/""Users/[^[:space:]]+"; \
	! rg -n -i "$${pair_re}|$${secret_re}|$${node_re}|$${auth_re}|$${ts_ips_re}|$${allowed_ips_re}|$${path_re}" . --hidden -g '!.git/**' -g '!LICENSE.md'
	@echo "Repository privacy scan passed."

lint: ## Lint Markdown and shell scripts
	@$(MARKDOWNLINT) --config "$(MARKDOWNLINT_CONFIG)" $(MARKDOWN_FILES)
	@$(SHELLCHECK) --enable=all $(SHELL_FILES)

check: lint compose-config privacy-check ## Run local validation checks
