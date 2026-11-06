# ==============================================================================
# Dynamic Secret Management with KSOPS & SOPS
# ==============================================================================
# Variables (can be overridden via command line: make <target> APP=... ENV=...)
APP          ?= authorizer-service
ENV          ?= dev
SECRET_NAME  ?= $(APP)-secret
NAMESPACE    ?= $(APP)-$(ENV)
SECRETS_DIR  := secrets/$(APP)/$(ENV)
ENC_FILE     := $(SECRETS_DIR)/secret.enc.yaml

# Automatically look for the source .env file if not specified
ENV_FILE ?= $(shell \
	if [ -f "$(SECRETS_DIR)/.env" ]; then echo "$(SECRETS_DIR)/.env"; \
	elif [ -f "$(ENV).env" ]; then echo "$(ENV).env"; \
	elif [ -f ".env.$(ENV)" ]; then echo ".env.$(ENV)"; \
	elif [ -f ".env" ]; then echo ".env"; \
	fi)

# Set SOPS_AGE_KEY_FILE default if not already exported in the shell
export SOPS_AGE_KEY_FILE ?= $(HOME)/.config/sops/age/keys.txt

.PHONY: help
help:
	@echo "======================================================================"
	@echo "           K8s GitOps Secret Management (SOPS + KSOPS)               "
	@echo "======================================================================"
	@echo "Default variables:"
	@echo "  APP         : $(APP)"
	@echo "  ENV         : $(ENV)"
	@echo "  SECRET_NAME : $(SECRET_NAME)"
	@echo "  NAMESPACE   : $(NAMESPACE)"
	@echo "  TARGET DIR  : $(SECRETS_DIR)"
	@echo "  ENV_FILE    : $(if $(ENV_FILE),$(ENV_FILE),<not found>)"
	@echo ""
	@echo "Main Commands:"
	@echo "  make secret-init      - Initialize folder structure & KSOPS generator"
	@echo "  make secret-generate  - Generate & encrypt secret directly into secret.enc.yaml"
	@echo "  make secret-view      - View decrypted secret in terminal (zero plain file)"
	@echo "  make secret-edit      - Edit secret in-place via SOPS editor (safe)"
	@echo "  make secret-check     - Verify repo security before git commit (prevent plain secrets)"
	@echo ""
	@echo "Usage Examples:"
	@echo "  # 1. Default application (authorizer-service, dev):"
	@echo "  make secret-generate ENV_FILE=dev.env"
	@echo ""
	@echo "  # 2. Other application and staging env:"
	@echo "  make secret-generate APP=lms-service ENV=staging ENV_FILE=path/to/.env.staging"
	@echo ""
	@echo "  # 3. Initialize a new application:"
	@echo "  make secret-init APP=payment-service ENV=production"
	@echo ""
	@echo "  # 4. View / Edit secret:"
	@echo "  make secret-view APP=authorizer-service ENV=dev"
	@echo "  make secret-edit APP=authorizer-service ENV=dev"
	@echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. Initialize KSOPS directory for any App & Env
# ------------------------------------------------------------------------------
.PHONY: secret-init
secret-init:
	@echo "==> Initializing KSOPS for APP='$(APP)' ENV='$(ENV)' in $(SECRETS_DIR)..."
	@mkdir -p $(SECRETS_DIR)
	@# Generate kustomization.yaml if it does not exist
	@if [ ! -f "$(SECRETS_DIR)/kustomization.yaml" ]; then \
		printf "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n# Wave -3: Secret exists before the job hooks (-2/-1) and workloads (0).\ncommonAnnotations:\n  argocd.argoproj.io/sync-wave: \"-3\"\ngenerators:\n  - secret-generator.yaml\n" > $(SECRETS_DIR)/kustomization.yaml; \
		echo "    [+] Created: $(SECRETS_DIR)/kustomization.yaml"; \
	fi
	@# Generate secret-generator.yaml if it does not exist
	@if [ ! -f "$(SECRETS_DIR)/secret-generator.yaml" ]; then \
		printf "apiVersion: viaduct.ai/v1\nkind: Ksops\nmetadata:\n  name: $(SECRET_NAME)-generator\n  annotations:\n    config.kubernetes.io/function: |\n      exec:\n        path: ksops\nfiles:\n  - secret.enc.yaml\n" > $(SECRETS_DIR)/secret-generator.yaml; \
		echo "    [+] Created: $(SECRETS_DIR)/secret-generator.yaml"; \
	fi
	@# Create .env.example template as a team reference
	@if [ ! -f "$(SECRETS_DIR)/.env.example" ]; then \
		printf "# Environment template for $(APP) ($(ENV))\n# Copy to a local .env file (do not commit)\n# Example: KEY=VALUE\n" > $(SECRETS_DIR)/.env.example; \
		echo "    [+] Created: $(SECRETS_DIR)/.env.example"; \
	fi
	@echo "==> KSOPS initialization complete."

# ------------------------------------------------------------------------------
# 2. Dynamically Generate & Encrypt Secret (Stream pipeline, zero plain-on-disk)
# ------------------------------------------------------------------------------
.PHONY: secret-generate
secret-generate: secret-init
	@# 1. Validate Age key file existence
	@if [ ! -f "$$SOPS_AGE_KEY_FILE" ]; then \
		echo "ERROR: SOPS_AGE_KEY_FILE key file not found at: $$SOPS_AGE_KEY_FILE" >&2; \
		echo "Ensure the age key has been generated or export SOPS_AGE_KEY_FILE=/path/to/keys.txt" >&2; \
		exit 1; \
	fi
	@# 2. Validate source env file
	@if [ -z "$(ENV_FILE)" ] || [ ! -f "$(ENV_FILE)" ]; then \
		echo "ERROR: Source env file not found!" >&2; \
		echo "Please create an env file or specify it with parameter:" >&2; \
		echo "  make secret-generate APP=$(APP) ENV=$(ENV) ENV_FILE=/path/to/your.env" >&2; \
		exit 1; \
	fi
	@echo "==> Processing secret for APP='$(APP)' ENV='$(ENV)' from '$(ENV_FILE)'..."
	@# 3. Stream pipeline: kubectl -> sops (zero plaintext YAML on disk)
	@kubectl create secret generic $(SECRET_NAME) \
		--namespace=$(NAMESPACE) \
		--from-env-file=$(ENV_FILE) \
		--dry-run=client -o yaml | \
	sops --encrypt \
		--filename-override $(ENC_FILE) \
		--encrypted-regex '^(data|stringData)$$' \
		/dev/stdin > $(ENC_FILE)
	@# 4. Security validation: ensure output file is properly encrypted
	@if ! grep -q "sops:" $(ENC_FILE) || ! grep -q "ENC\[AES256_GCM" $(ENC_FILE); then \
		echo "CRITICAL ERROR: Encryption failed or invalid file! Removing unsafe file..." >&2; \
		rm -f $(ENC_FILE); \
		exit 1; \
	fi
	@echo "==> SUCCESS! Encrypted secret saved at: $(ENC_FILE)"
	@echo "    Plaintext YAML was NEVER written to disk."
	@echo "    IMPORTANT: Ensure '$(ENV_FILE)' is not committed to Git!"

# ------------------------------------------------------------------------------
# 3. View & Edit Encrypted Secrets
# ------------------------------------------------------------------------------
.PHONY: secret-view
secret-view:
	@if [ ! -f "$(ENC_FILE)" ]; then \
		echo "ERROR: File $(ENC_FILE) not found!" >&2; \
		exit 1; \
	fi
	@echo "==> Displaying decrypted content for $(ENC_FILE) (terminal only):"
	@sops -d $(ENC_FILE)

.PHONY: secret-edit
secret-edit:
	@if [ ! -f "$(ENC_FILE)" ]; then \
		echo "ERROR: File $(ENC_FILE) not found!" >&2; \
		exit 1; \
	fi
	@echo "==> Opening $(ENC_FILE) in SOPS editor (auto re-encrypts upon save)..."
	@sops $(ENC_FILE)

# ------------------------------------------------------------------------------
# 4. Security: Check Git Staging to Prevent Plain Secrets from Being Pushed
# ------------------------------------------------------------------------------
.PHONY: secret-check
secret-check:
	@echo "==> Running git staging security audit..."
	@STAGED_LEAKS=$$(git diff --cached --name-only | grep -E '(\.env(\..+)?$$|\.dec\.ya?ml$$|\.plain\.ya?ml$$|secret-.*\.ya?ml$$)' | grep -v '\.env\.example$$' | grep -v 'secret-generator' || true); \
	if [ -n "$$STAGED_LEAKS" ]; then \
		echo "=================================================================" >&2; \
		echo "CRITICAL SECURITY ALERT: Plain secret files found in git staging!" >&2; \
		echo "$$STAGED_LEAKS" >&2; \
		echo "Do not commit these files! Run: git reset HEAD <file> to unstage." >&2; \
		echo "=================================================================" >&2; \
		exit 1; \
	fi; \
	UNENCRYPTED_SECRETS=$$(git diff --cached --name-only | grep -E '^secrets/.*\.ya?ml$$' | grep -v 'secret\.enc\.' | grep -v 'kustomization\.' | grep -v 'secret-generator\.' || true); \
	if [ -n "$$UNENCRYPTED_SECRETS" ]; then \
		echo "=================================================================" >&2; \
		echo "CRITICAL SECURITY ALERT: Unencrypted YAML found in secrets/ directory!" >&2; \
		echo "$$UNENCRYPTED_SECRETS" >&2; \
		echo "Only *.enc.yaml files are allowed to be committed to Git!" >&2; \
		echo "=================================================================" >&2; \
		exit 1; \
	fi
	@echo "==> SECURE: No plain secrets or .env files staged in git."

# ------------------------------------------------------------------------------
# 5. Aliases for backward compatibility
# ------------------------------------------------------------------------------
.PHONY: generate-secret-dev encrypt-secret-dev generate-secret-prod encrypt-secret-prod
generate-secret-dev:
	@$(MAKE) secret-generate APP=authorizer-service ENV=dev ENV_FILE=dev.env

encrypt-secret-dev:
	@echo "Note: In this version, secrets are automatically encrypted during 'make secret-generate'."

generate-secret-prod:
	@$(MAKE) secret-generate APP=authorizer-service ENV=production ENV_FILE=prod.env

encrypt-secret-prod:
	@echo "Note: In this version, secrets are automatically encrypted during 'make secret-generate'."
