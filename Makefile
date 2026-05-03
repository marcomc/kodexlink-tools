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
HTTPS_PORT ?=
RELAY_UPSTREAM_URL ?= https://github.com/David699/codex-mobile-relay.git
RELAY_SOURCE_DIR ?= $(HOME)/.local/share/kodexlink-tools/codex-mobile-relay
RELAY_SCRIPT = KODEXLINK_RELAY_ENV_FILE="$(ENV_FILE)" ./scripts/kodexlink-relay.sh

MARKDOWN_FILES := README.md TODO.md CHANGELOG.md LICENSE.md docs/*.md
SHELL_FILES := scripts/kodexlink-relay.sh scripts/tailscale-cli-launcher

.DEFAULT_GOAL := help

.PHONY: help check-deps require-kodexlink require-npm require-tailscale docker-start fetch-relay-source update-relay-source ensure-env configure-relay-source configure-url configure-https-port install install-all update enable disable install-relay install-tool-cli update-tool-cli install-tool install-tailscale-cli tailscale-serve tailscale-serve-off tailscale-funnel tailscale-funnel-off pair start stop restart status logs health curl measure print-url compose-config doctor doctor-relay doctor-tailscale doctor-mobile privacy-check lint check

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
		KODEXLINK_RELAY_REPO="$(RELAY_SOURCE_DIR)" $(RELAY_SCRIPT) init-env "$$initial_url"; \
	fi

configure-relay-source: ensure-env ## Point relay.env at the managed upstream source checkout
	@$(RELAY_SCRIPT) set-relay-repo "$(RELAY_SOURCE_DIR)"

configure-url: ensure-env ## Prompt for or set the relay public HTTPS URL
	@configured_url="$$($(RELAY_SCRIPT) public-url 2>/dev/null || true)"; \
	public_url="$(PUBLIC_URL)"; \
	if [[ -n "$$public_url" ]]; then \
		$(RELAY_SCRIPT) set-public-url "$$public_url"; \
	elif [[ -n "$$configured_url" && "$$configured_url" != "$(DEFAULT_PUBLIC_URL)" ]]; then \
		echo "Reusing relay URL from $(ENV_FILE): $$configured_url"; \
	else \
		read -r -p "Relay HTTPS URL, for example https://machine-name.tailnet-name.ts.net: " public_url; \
		if [[ -z "$$public_url" ]]; then \
			echo "No relay URL provided."; \
			exit 1; \
		fi; \
		$(RELAY_SCRIPT) set-public-url "$$public_url"; \
	fi

configure-https-port: ensure-env ## Persist the shared Tailscale Serve/Funnel HTTPS port: 443, 8443, or 10000
	@https_port="$(HTTPS_PORT)"; \
	if [[ -z "$$https_port" ]]; then \
		read -r -p "Tailscale HTTPS port (443, 8443, or 10000): " https_port; \
	fi; \
	if [[ -z "$$https_port" ]]; then \
		echo "No HTTPS port provided."; \
		exit 1; \
	fi; \
	$(RELAY_SCRIPT) set-https-port "$$https_port"

install: install-all ## Install and configure everything without enabling services

install-all: ## Install CLI launcher, upstream relay source, env, and desktop CLI
	@$(MAKE) install-tailscale-cli
	@$(MAKE) fetch-relay-source
	@$(MAKE) ensure-env
	@$(MAKE) configure-relay-source
	@if [[ -n "$(HTTPS_PORT)" ]]; then $(MAKE) configure-https-port HTTPS_PORT="$(HTTPS_PORT)"; fi
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
	@$(RELAY_SCRIPT) desktop-service-stop || true
	@$(RELAY_SCRIPT) tailscale-serve-off || true
	@$(RELAY_SCRIPT) down || true

install-relay: ## Install and start the Docker relay stack
	@$(MAKE) docker-start
	@$(MAKE) fetch-relay-source
	@$(MAKE) ensure-env
	@$(MAKE) configure-relay-source
	@$(RELAY_SCRIPT) up

install-tool-cli: require-npm ## Install the KodexLink desktop CLI from npm if missing
	@if command -v "$(KODEXLINK)" >/dev/null 2>&1; then \
		"$(KODEXLINK)" --version 2>/dev/null || "$(KODEXLINK)" doctor 2>/dev/null || true; \
	else \
		"$(NPM)" install -g kodexlink; \
	fi

update-tool-cli: require-npm ## Update the KodexLink desktop CLI from npm
	@"$(NPM)" install -g kodexlink@latest

install-tool: ensure-env install-tool-cli require-kodexlink ## Install the KodexLink desktop LaunchAgent
	@$(RELAY_SCRIPT) desktop-service-install

install-tailscale-cli: ## Install or refresh /usr/local/bin/tailscale
	@sudo install -m 0755 scripts/tailscale-cli-launcher /usr/local/bin/tailscale
	@/usr/local/bin/tailscale version

tailscale-serve: ensure-env require-tailscale ## Publish the relay privately with Tailscale Serve
	@$(RELAY_SCRIPT) tailscale-serve

tailscale-serve-off: require-tailscale ## Disable the Tailscale Serve HTTPS 443 proxy
	@$(RELAY_SCRIPT) tailscale-serve-off

tailscale-funnel: ensure-env require-tailscale ## Publish the relay publicly with Tailscale Funnel
	@$(RELAY_SCRIPT) tailscale-funnel

tailscale-funnel-off: require-tailscale ## Disable the Tailscale Funnel HTTPS 443 public proxy
	@$(RELAY_SCRIPT) tailscale-funnel-off

pair: ensure-env require-kodexlink ## Open the local QR pairing panel
	@$(RELAY_SCRIPT) desktop-pair

start: ## Start the Docker relay stack
	@$(MAKE) docker-start
	@$(RELAY_SCRIPT) up

stop: ## Stop the Docker relay stack
	@$(RELAY_SCRIPT) down

restart: ## Restart the Docker relay stack
	@$(MAKE) docker-start
	@$(RELAY_SCRIPT) restart

status: ## Show relay container status and desktop agent status
	@$(RELAY_SCRIPT) status
	@echo
	@$(RELAY_SCRIPT) desktop-status || true

logs: ## Follow compose logs, optionally SERVICE=relay
	@$(RELAY_SCRIPT) logs $(SERVICE)

health: ## Check local relay health
	@$(RELAY_SCRIPT) health

curl: ## Fetch relay JSON, defaulting to /healthz; use PUBLIC=1 for the mobile-facing HTTPS URL and RELAY_PATH=/ for another path
	@scope=local; \
	if [[ "$(PUBLIC)" == "1" ]]; then \
		scope=public; \
	fi; \
	relay_path="$(if $(RELAY_PATH),$(RELAY_PATH),/healthz)"; \
	$(RELAY_SCRIPT) curl-relay "$$relay_path" "$$scope"

measure: ## Show one-shot Docker CPU and memory usage
	@$(RELAY_SCRIPT) measure

print-url: ## Print the configured relay public URL
	@$(RELAY_SCRIPT) public-url

compose-config: ensure-env ## Validate the Docker Compose configuration
	@KODEXLINK_TOOLS_DIR="$(CURDIR)" "$(DOCKER)" compose --env-file "$(ENV_FILE)" -f "$(COMPOSE_FILE)" config >/dev/null

doctor: doctor-relay doctor-tailscale doctor-mobile privacy-check ## Run setup diagnostics

doctor-relay: ensure-env compose-config ## Check relay configuration and local health
	@$(RELAY_SCRIPT) health >/dev/null
	@echo "Relay health endpoint is reachable on localhost."

doctor-tailscale: require-tailscale ## Check Tailscale CLI and Serve mapping
	@"$(TAILSCALE)" status >/dev/null
	@"$(TAILSCALE)" serve status >/dev/null
	@echo "Tailscale CLI and Serve status are available."

doctor-mobile: ensure-env ## Check mobile-facing relay URL basics
	@public_url="$$($(RELAY_SCRIPT) public-url)"; \
	case "$${public_url:-}" in \
		https://*) echo "Mobile relay URL is configured as HTTPS."; ;; \
		*) echo "Mobile relay URL should be an HTTPS Tailscale Serve URL before pairing."; exit 1; ;; \
	esac; \
	if ! $(RELAY_SCRIPT) curl-relay /healthz public >/dev/null; then \
		echo "Mobile-facing relay health check failed."; \
		echo "If the node hostname or HTTPS certificate changed, run 'make configure-url PUBLIC_URL=https://your-node.your-tailnet.ts.net' and then 'make enable'."; \
		exit 1; \
	fi; \
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
