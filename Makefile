# ==============================================================================
# Dynamic Secret Management with KSOPS & SOPS
# ==============================================================================
# Variables (bisa di-override lewat command line: make <target> APP=... ENV=...)
APP          ?= authorizer-service
ENV          ?= dev
SECRET_NAME  ?= $(APP)-secret
NAMESPACE    ?= $(APP)-$(ENV)
SECRETS_DIR  := secrets/$(APP)/$(ENV)
ENC_FILE     := $(SECRETS_DIR)/secret.enc.yaml

# Cari file .env sumber secara otomatis jika tidak dispesifikasikan
ENV_FILE ?= $(shell \
	if [ -f "$(SECRETS_DIR)/.env" ]; then echo "$(SECRETS_DIR)/.env"; \
	elif [ -f "$(ENV).env" ]; then echo "$(ENV).env"; \
	elif [ -f ".env.$(ENV)" ]; then echo ".env.$(ENV)"; \
	elif [ -f ".env" ]; then echo ".env"; \
	fi)

# Usahakan SOPS_AGE_KEY_FILE terpasang jika belum diexport di shell
export SOPS_AGE_KEY_FILE ?= $(HOME)/.config/sops/age/keys.txt

.PHONY: help
help:
	@echo "======================================================================"
	@echo "           K8s GitOps Secret Management (SOPS + KSOPS)               "
	@echo "======================================================================"
	@echo "Variabel default:"
	@echo "  APP         : $(APP)"
	@echo "  ENV         : $(ENV)"
	@echo "  SECRET_NAME : $(SECRET_NAME)"
	@echo "  NAMESPACE   : $(NAMESPACE)"
	@echo "  TARGET DIR  : $(SECRETS_DIR)"
	@echo "  ENV_FILE    : $(if $(ENV_FILE),$(ENV_FILE),<belum ditemukan>)"
	@echo ""
	@echo "Perintah Utama:"
	@echo "  make secret-init      - Inisialisasi struktur folder & KSOPS generator"
	@echo "  make secret-generate  - Generate & encrypt secret langsung ke secret.enc.yaml"
	@echo "  make secret-view      - Lihat isi secret terdekripsi ke terminal (tanpa file plain)"
	@echo "  make secret-edit      - Edit secret secara in-place via editor SOPS (aman)"
	@echo "  make secret-check     - Cek keamanan repo sebelum git commit (anti plain secret)"
	@echo ""
	@echo "Contoh Penggunaan:"
	@echo "  # 1. Aplikasi default (authorizer-service, dev):"
	@echo "  make secret-generate ENV_FILE=dev.env"
	@echo ""
	@echo "  # 2. Aplikasi lain dan env staging:"
	@echo "  make secret-generate APP=lms-service ENV=staging ENV_FILE=path/to/.env.staging"
	@echo ""
	@echo "  # 3. Inisialisasi aplikasi baru:"
	@echo "  make secret-init APP=payment-service ENV=production"
	@echo ""
	@echo "  # 4. View / Edit secret:"
	@echo "  make secret-view APP=authorizer-service ENV=dev"
	@echo "  make secret-edit APP=authorizer-service ENV=dev"
	@echo "======================================================================"

# ------------------------------------------------------------------------------
# 1. Inisialisasi folder KSOPS untuk App & Env apa saja
# ------------------------------------------------------------------------------
.PHONY: secret-init
secret-init:
	@echo "==> Menginisialisasi KSOPS untuk APP='$(APP)' ENV='$(ENV)' di $(SECRETS_DIR)..."
	@mkdir -p $(SECRETS_DIR)
	@# Generate kustomization.yaml jika belum ada
	@if [ ! -f "$(SECRETS_DIR)/kustomization.yaml" ]; then \
		printf "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\ngenerators:\n  - secret-generator.yaml\n" > $(SECRETS_DIR)/kustomization.yaml; \
		echo "    [+] Dibuat: $(SECRETS_DIR)/kustomization.yaml"; \
	fi
	@# Generate secret-generator.yaml jika belum ada
	@if [ ! -f "$(SECRETS_DIR)/secret-generator.yaml" ]; then \
		printf "apiVersion: viaduct.ai/v1\nkind: Ksops\nmetadata:\n  name: $(SECRET_NAME)-generator\n  annotations:\n    config.kubernetes.io/function: |\n      exec:\n        path: ksops\nfiles:\n  - secret.enc.yaml\n" > $(SECRETS_DIR)/secret-generator.yaml; \
		echo "    [+] Dibuat: $(SECRETS_DIR)/secret-generator.yaml"; \
	fi
	@# Buat template .env.example sebagai referensi tim
	@if [ ! -f "$(SECRETS_DIR)/.env.example" ]; then \
		printf "# Template env untuk $(APP) ($(ENV))\n# Copy ke file .env lokal (jangan dicommit)\n# Contoh: KEY=VALUE\n" > $(SECRETS_DIR)/.env.example; \
		echo "    [+] Dibuat: $(SECRETS_DIR)/.env.example"; \
	fi
	@echo "==> Inisialisasi KSOPS selesai."

# ------------------------------------------------------------------------------
# 2. Generate & Encrypt Secret secara Dinamis (Stream pipeline, zero plain-on-disk)
# ------------------------------------------------------------------------------
.PHONY: secret-generate
secret-generate: secret-init
	@# 1. Validasi keberadaan kunci Age
	@if [ ! -f "$$SOPS_AGE_KEY_FILE" ]; then \
		echo "ERROR: File kunci SOPS_AGE_KEY_FILE tidak ditemukan di: $$SOPS_AGE_KEY_FILE" >&2; \
		echo "Pastikan kunci age sudah digenerate atau set export SOPS_AGE_KEY_FILE=/path/to/keys.txt" >&2; \
		exit 1; \
	fi
	@# 2. Validasi file env sumber
	@if [ -z "$(ENV_FILE)" ] || [ ! -f "$(ENV_FILE)" ]; then \
		echo "ERROR: File env sumber tidak ditemukan!" >&2; \
		echo "Silakan buat file env atau jalankan dengan parameter:" >&2; \
		echo "  make secret-generate APP=$(APP) ENV=$(ENV) ENV_FILE=/path/to/your.env" >&2; \
		exit 1; \
	fi
	@echo "==> Memproses secret untuk APP='$(APP)' ENV='$(ENV)' dari '$(ENV_FILE)'..."
	@# 3. Stream pipeline: kubectl -> sops (zero plaintext YAML on disk)
	@kubectl create secret generic $(SECRET_NAME) \
		--namespace=$(NAMESPACE) \
		--from-env-file=$(ENV_FILE) \
		--dry-run=client -o yaml | \
	sops --encrypt \
		--filename-override $(ENC_FILE) \
		--encrypted-regex '^(data|stringData)$$' \
		/dev/stdin > $(ENC_FILE)
	@# 4. Validasi keamanan: pastikan file output benar-benar terenkripsi
	@if ! grep -q "sops:" $(ENC_FILE) || ! grep -q "ENC\[AES256_GCM" $(ENC_FILE); then \
		echo "CRITICAL ERROR: Enkripsi gagal atau file tidak valid! Menghapus file tidak aman..." >&2; \
		rm -f $(ENC_FILE); \
		exit 1; \
	fi
	@echo "==> BERHASIL! Secret terenkripsi disimpan di: $(ENC_FILE)"
	@echo "    File plaintext YAML TIDAK PERNAH disimpan di disk."
	@echo "    PENTING: Pastikan file '$(ENV_FILE)' tidak di-commit ke Git!"

# ------------------------------------------------------------------------------
# 3. View & Edit Secret Terenkripsi
# ------------------------------------------------------------------------------
.PHONY: secret-view
secret-view:
	@if [ ! -f "$(ENC_FILE)" ]; then \
		echo "ERROR: File $(ENC_FILE) tidak ditemukan!" >&2; \
		exit 1; \
	fi
	@echo "==> Menampilkan isi terdekripsi untuk $(ENC_FILE) (hanya di terminal):"
	@sops -d $(ENC_FILE)

.PHONY: secret-edit
secret-edit:
	@if [ ! -f "$(ENC_FILE)" ]; then \
		echo "ERROR: File $(ENC_FILE) tidak ditemukan!" >&2; \
		exit 1; \
	fi
	@echo "==> Membuka $(ENC_FILE) di SOPS editor (re-encrypt otomatis saat disimpan)..."
	@sops $(ENC_FILE)

# ------------------------------------------------------------------------------
# 4. Keamanan: Cek Git Staging agar Jangan Sampai Plain Secret Ter-push
# ------------------------------------------------------------------------------
.PHONY: secret-check
secret-check:
	@echo "==> Menjalankan audit keamanan staging git..."
	@STAGED_LEAKS=$$(git diff --cached --name-only | grep -E '(\.env(\..+)?$$|\.dec\.ya?ml$$|\.plain\.ya?ml$$|secret-.*\.ya?ml$$)' | grep -v '\.env\.example$$' | grep -v 'secret-generator' || true); \
	if [ -n "$$STAGED_LEAKS" ]; then \
		echo "=================================================================" >&2; \
		echo "CRITICAL SECURITY ALERT: Ditemukan file plain secret di git staging!" >&2; \
		echo "$$STAGED_LEAKS" >&2; \
		echo "Jangan commit file ini! Jalankan: git reset HEAD <file> untuk unstage." >&2; \
		echo "=================================================================" >&2; \
		exit 1; \
	fi; \
	UNENCRYPTED_SECRETS=$$(git diff --cached --name-only | grep -E '^secrets/.*\.ya?ml$$' | grep -v 'secret\.enc\.' | grep -v 'kustomization\.' | grep -v 'secret-generator\.' || true); \
	if [ -n "$$UNENCRYPTED_SECRETS" ]; then \
		echo "=================================================================" >&2; \
		echo "CRITICAL SECURITY ALERT: Ditemukan YAML tak terenkripsi di folder secrets/!" >&2; \
		echo "$$UNENCRYPTED_SECRETS" >&2; \
		echo "Hanya file *.enc.yaml yang boleh di-commit ke Git!" >&2; \
		echo "=================================================================" >&2; \
		exit 1; \
	fi
	@echo "==> AMAN: Tidak ada plain secret atau file .env yang ter-stage di git."

# ------------------------------------------------------------------------------
# 5. Alias untuk kompatibilitas script lama
# ------------------------------------------------------------------------------
.PHONY: generate-secret-dev encrypt-secret-dev generate-secret-prod encrypt-secret-prod
generate-secret-dev:
	@$(MAKE) secret-generate APP=authorizer-service ENV=dev ENV_FILE=dev.env

encrypt-secret-dev:
	@echo "Catatan: Pada versi baru, secret langsung terenkripsi otomatis saat 'make secret-generate'."

generate-secret-prod:
	@$(MAKE) secret-generate APP=authorizer-service ENV=production ENV_FILE=prod.env

encrypt-secret-prod:
	@echo "Catatan: Pada versi baru, secret langsung terenkripsi otomatis saat 'make secret-generate'."
