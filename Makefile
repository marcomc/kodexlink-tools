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
RELAY_RUNTIME ?= docker
NATIVE_DEPS ?= external
DATABASE_URL ?=
REDIS_URL ?=
RELAY_UPSTREAM_URL ?= https://github.com/David699/codex-mobile-relay.git
RELAY_SOURCE_DIR ?= $(HOME)/.local/share/kodexlink-tools/codex-mobile-relay

MARKDOWN_FILES := README.md TODO.md CHANGELOG.md LICENSE.md docs/*.md
SHELL_FILES := scripts/kodexlink-relay.sh scripts/tailscale-cli-launcher tests/relay-runtime-makefile-test.sh

ifeq ($(RELAY_RUNTIME),docker)
CHECK_REQUIRED_COMMANDS := "$(DOCKER)" "$(GIT)" curl
RELAY_INSTALL_TARGET := install-relay-docker-prep
RELAY_ENABLE_TARGET := enable-relay-docker
RELAY_UPDATE_TARGET := update-relay-docker
RELAY_START_TARGET := start-relay-docker
RELAY_STOP_TARGET := stop-relay-docker
RELAY_RESTART_TARGET := restart-relay-docker
RELAY_STATUS_TARGET := status-relay-docker
RELAY_LOGS_TARGET := logs-relay-docker
RELAY_MEASURE_TARGET := measure-relay-docker
RELAY_CONFIG_CHECK_TARGET := compose-config
else ifeq ($(RELAY_RUNTIME),native)
ifneq ($(NATIVE_DEPS),external)
ifneq ($(NATIVE_DEPS),managed)
$(error NATIVE_DEPS must be external or managed)
endif
endif
CHECK_REQUIRED_COMMANDS := "$(GIT)" curl
RELAY_INSTALL_TARGET := install-relay-native
RELAY_ENABLE_TARGET := enable-relay-native
RELAY_UPDATE_TARGET := update-relay-native
RELAY_START_TARGET := native-start
RELAY_STOP_TARGET := native-stop
RELAY_RESTART_TARGET := native-restart
RELAY_STATUS_TARGET := native-status
RELAY_LOGS_TARGET := native-logs
RELAY_MEASURE_TARGET := native-measure
RELAY_CONFIG_CHECK_TARGET := native-config-check
else
$(error RELAY_RUNTIME must be docker or native)
endif

.DEFAULT_GOAL := help

.PHONY: help check-deps require-kodexlink require-npm require-tailscale docker-start fetch-relay-source update-relay-source ensure-env configure-relay-source configure-url install install-all update enable disable install-relay install-relay-docker install-relay-docker-prep install-relay-native enable-relay-docker enable-relay-native update-relay-docker update-relay-native install-tool-cli update-tool-cli install-tool install-tailscale-cli tailscale-serve tailscale-serve-off tailscale-funnel tailscale-funnel-off pair start stop restart status logs health measure print-url compose-config native-config-check doctor doctor-relay doctor-tailscale doctor-mobile privacy-check lint check test start-relay-docker stop-relay-docker restart-relay-docker status-relay-docker logs-relay-docker measure-relay-docker native-start native-stop native-restart native-status native-logs native-measure

help: ## Show available targets
	@awk 'BEGIN { FS = ":.*##" } /^[a-zA-Z_-]+:.*##/ { printf "  %-24s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

check-deps: ## Check common command dependencies
	@missing=0; \
	for cmd in $(CHECK_REQUIRED_COMMANDS); do \
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
		case "$$(uname -s)" in \
			Darwin) \
				echo "Starting Docker Desktop..."; \
				open -ga Docker; \
				;; \
			Linux) \
				echo "Starting Docker service..."; \
				if command -v systemctl >/dev/null 2>&1; then \
					sudo systemctl start docker; \
				else \
					echo "Docker is not running and systemctl is unavailable."; \
					exit 1; \
				fi; \
				;; \
			*) \
				echo "Docker is not running and this OS is unsupported by docker-start."; \
				exit 1; \
				;; \
		esac; \
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
	@$(MAKE) $(RELAY_INSTALL_TARGET)
	@$(MAKE) install-tool-cli
	@echo "Install complete. Services are configured but not enabled."
	@echo "Run 'make enable RELAY_RUNTIME=$(RELAY_RUNTIME)' to start the relay, Tailscale Serve, and the KodexLink desktop service."

update: ## Update relay source and desktop CLI without deleting pairing data
	@$(MAKE) fetch-relay-source
	@$(MAKE) configure-relay-source
	@$(MAKE) update-tool-cli
	@$(MAKE) $(RELAY_UPDATE_TARGET)
	@$(MAKE) install-tool
	@echo "Update complete. Existing paired devices are preserved because relay storage and the relay URL were not reset."

enable: ## Enable all runtime services
	@$(MAKE) ensure-env
	@$(MAKE) $(RELAY_ENABLE_TARGET)
	@$(MAKE) tailscale-serve
	@$(MAKE) install-tool
	@echo "Services enabled. Set the same HTTPS relay URL in the mobile app Custom Address, then run 'make pair'."

disable: ## Disable all runtime services without deleting data
	@./scripts/kodexlink-relay.sh desktop-service-stop || true
	@./scripts/kodexlink-relay.sh tailscale-serve-off || true
	@$(MAKE) stop || true

install-relay: install-relay-docker ## Install and start the Docker relay stack

install-relay-docker: ## Install and start the Docker relay stack
	@$(MAKE) docker-start
	@$(MAKE) fetch-relay-source
	@$(MAKE) ensure-env
	@$(MAKE) configure-relay-source
	@./scripts/kodexlink-relay.sh up

install-relay-docker-prep: ## Prepare Docker relay configuration without starting containers
	@echo "Docker relay will be built and started by 'make enable' or 'make start'."

install-relay-native: ## Install native relay with NATIVE_DEPS=external or managed
	@$(MAKE) fetch-relay-source
	@$(MAKE) ensure-env
	@$(MAKE) configure-relay-source
	@KODEXLINK_NATIVE_DEPS="$(NATIVE_DEPS)" DATABASE_URL="$(DATABASE_URL)" REDIS_URL="$(REDIS_URL)" ./scripts/kodexlink-relay.sh native-install

enable-relay-docker: ## Start the Docker relay stack for enable
	@$(MAKE) docker-start
	@$(MAKE) start-relay-docker

enable-relay-native: ## Start the native relay service for enable
	@$(MAKE) native-start

update-relay-docker: ## Rebuild and restart the Docker relay stack
	@$(MAKE) restart-relay-docker

update-relay-native: ## Rebuild and restart the native relay service
	@KODEXLINK_NATIVE_DEPS="$(NATIVE_DEPS)" DATABASE_URL="$(DATABASE_URL)" REDIS_URL="$(REDIS_URL)" ./scripts/kodexlink-relay.sh native-build
	@$(MAKE) native-restart

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
	@case "$$(uname -s)" in \
		Darwin) \
			sudo install -m 0755 scripts/tailscale-cli-launcher /usr/local/bin/tailscale; \
			/usr/local/bin/tailscale version; \
			;; \
		Linux) \
			if command -v "$(TAILSCALE)" >/dev/null 2>&1; then \
				"$(TAILSCALE)" version; \
			else \
				echo "Install Tailscale for Linux first: https://tailscale.com/download/linux"; \
				exit 1; \
			fi; \
			;; \
		*) \
			echo "Unsupported OS for install-tailscale-cli."; \
			exit 1; \
			;; \
	esac

tailscale-serve: ensure-env require-tailscale ## Publish the relay privately with Tailscale Serve
	@./scripts/kodexlink-relay.sh tailscale-serve

tailscale-serve-off: require-tailscale ## Disable the Tailscale Serve HTTPS 443 proxy
	@./scripts/kodexlink-relay.sh tailscale-serve-off

tailscale-funnel: ensure-env require-tailscale ## Publish the relay publicly with Tailscale Funnel
	@./scripts/kodexlink-relay.sh tailscale-funnel

tailscale-funnel-off: require-tailscale ## Disable the Tailscale Funnel HTTPS 443 public proxy
	@./scripts/kodexlink-relay.sh tailscale-funnel-off

pair: ensure-env require-kodexlink ## Open the local QR pairing panel
	@./scripts/kodexlink-relay.sh desktop-pair

start: ## Start the selected relay runtime
	@$(MAKE) $(RELAY_START_TARGET)

stop: ## Stop the selected relay runtime
	@$(MAKE) $(RELAY_STOP_TARGET)

restart: ## Restart the selected relay runtime
	@$(MAKE) $(RELAY_RESTART_TARGET)

status: ## Show selected relay runtime status and desktop agent status
	@$(MAKE) $(RELAY_STATUS_TARGET)
	@echo
	@./scripts/kodexlink-relay.sh desktop-status || true

logs: ## Follow selected relay logs, optionally SERVICE=relay for Docker
	@$(MAKE) $(RELAY_LOGS_TARGET)

measure: ## Show one-shot selected relay runtime CPU and memory usage
	@$(MAKE) $(RELAY_MEASURE_TARGET)

start-relay-docker: ## Start the Docker relay stack
	@$(MAKE) docker-start
	@./scripts/kodexlink-relay.sh up

stop-relay-docker: ## Stop the Docker relay stack
	@./scripts/kodexlink-relay.sh down

restart-relay-docker: ## Restart the Docker relay stack
	@$(MAKE) docker-start
	@./scripts/kodexlink-relay.sh restart

status-relay-docker: ## Show relay container status
	@./scripts/kodexlink-relay.sh status

logs-relay-docker: ## Follow compose logs, optionally SERVICE=relay
	@./scripts/kodexlink-relay.sh logs $(SERVICE)

native-start: ## Start the native relay service
	@KODEXLINK_NATIVE_DEPS="$(NATIVE_DEPS)" DATABASE_URL="$(DATABASE_URL)" REDIS_URL="$(REDIS_URL)" ./scripts/kodexlink-relay.sh native-service-start

native-stop: ## Stop the native relay service
	@./scripts/kodexlink-relay.sh native-service-stop

native-restart: ## Restart the native relay service
	@KODEXLINK_NATIVE_DEPS="$(NATIVE_DEPS)" DATABASE_URL="$(DATABASE_URL)" REDIS_URL="$(REDIS_URL)" ./scripts/kodexlink-relay.sh native-service-restart

native-status: ## Show native relay service status
	@./scripts/kodexlink-relay.sh native-service-status

native-logs: ## Follow native relay service logs
	@./scripts/kodexlink-relay.sh native-service-logs

health: ## Check local relay health
	@./scripts/kodexlink-relay.sh health

measure-relay-docker: ## Show one-shot Docker CPU and memory usage
	@./scripts/kodexlink-relay.sh measure

native-measure: ## Show one-shot native relay CPU and memory usage
	@./scripts/kodexlink-relay.sh native-measure

print-url: ## Print the configured relay public URL
	@./scripts/kodexlink-relay.sh public-url

compose-config: ensure-env ## Validate the Docker Compose configuration
	@KODEXLINK_TOOLS_DIR="$(CURDIR)" "$(DOCKER)" compose --env-file "$(ENV_FILE)" -f "$(COMPOSE_FILE)" config >/dev/null

native-config-check: ensure-env ## Validate native relay service configuration
	@KODEXLINK_NATIVE_DEPS="$(NATIVE_DEPS)" DATABASE_URL="$(DATABASE_URL)" REDIS_URL="$(REDIS_URL)" ./scripts/kodexlink-relay.sh native-config-check

doctor: doctor-relay doctor-tailscale doctor-mobile privacy-check ## Run setup diagnostics

doctor-relay: ensure-env $(RELAY_CONFIG_CHECK_TARGET) ## Check selected relay configuration and local health
	@./scripts/kodexlink-relay.sh health >/dev/null
	@echo "Relay health endpoint is reachable on localhost."

doctor-tailscale: require-tailscale ## Check Tailscale CLI and Serve mapping
	@"$(TAILSCALE)" status >/dev/null
	@"$(TAILSCALE)" serve status >/dev/null
	@echo "Tailscale CLI and Serve status are available."

doctor-mobile: ensure-env ## Check mobile-facing relay URL basics
	@public_url="$$(KODEXLINK_RELAY_ENV_FILE="$(ENV_FILE)" ./scripts/kodexlink-relay.sh public-url)"; \
	case "$${public_url:-}" in \
		https://*) echo "Mobile relay URL is configured as HTTPS."; ;; \
		*) echo "Mobile relay URL should be an HTTPS Tailscale Serve URL before pairing."; exit 1; ;; \
	esac; \
	curl -fsS "$${public_url%/}/healthz" >/dev/null || exit 1; \
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

test: ## Run repository tests
	@bash tests/relay-runtime-makefile-test.sh

check: lint $(RELAY_CONFIG_CHECK_TARGET) privacy-check test ## Run local validation checks
