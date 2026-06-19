#!/usr/bin/env bash
#
# Deploy the Wagtail bakerydemo to Azure App Service (Free F1 tier).
# ---------------------------------------------------------------------------
# This script is reproducible and idempotent: every Azure CLI command below
# either creates a resource or updates it in place, so you can re-run the whole
# script safely (e.g. to push a new version of the code).
#
# What it provisions (all in one resource group, easy to delete afterwards):
#
#   * Resource group .................. logical container for everything below
#   * App Service plan (Linux, F1) .... the FREE compute tier ($0/month)
#   * Web App (Python 3.12) ........... runs the Django/Wagtail app via Gunicorn
#   * Storage account + blob container  holds user-uploaded media (a few cents)
#
# The database is SQLite on the App Service persistent /home volume, so there
# is no separate database resource to pay for. Search uses Wagtail's database
# backend and the cache is in-memory — no Redis or Elasticsearch needed.
#
# Prerequisites:
#   * Azure CLI installed and logged in:  az login
#   * Run from the repository root with your changes committed (the code is
#     deployed from `git archive HEAD`, i.e. tracked files at the current commit).
#
# Usage:
#   ./deploy/azure-deploy.sh
#
# Override any of the names/locations via environment variables, e.g.:
#   APP_NAME=my-bakery LOCATION=westeurope ./deploy/azure-deploy.sh
#
# Tear everything down (stops all charges) with:
#   az group delete --name "$RESOURCE_GROUP"
# ---------------------------------------------------------------------------
set -euo pipefail

# --- Configuration (override via environment variables) --------------------
# NOTE: APP_NAME and STORAGE_ACCOUNT must be GLOBALLY UNIQUE across Azure.
#       Change them if the defaults are taken.
RESOURCE_GROUP="${RESOURCE_GROUP:-bakerydemo-rg}"
LOCATION="${LOCATION:-uksouth}"
APP_PLAN="${APP_PLAN:-bakerydemo-plan}"
APP_NAME="${APP_NAME:-bakerydemo-$USER}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-bakerydemo$USER}"   # 3-24 chars, lowercase alphanumeric
MEDIA_CONTAINER="${MEDIA_CONTAINER:-media}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"

# App secrets. Override ADMIN_PASSWORD/DJANGO_SECRET_KEY for anything non-throwaway.
ADMIN_PASSWORD="${ADMIN_PASSWORD:-changeme}"
DJANGO_SECRET_KEY="${DJANGO_SECRET_KEY:-$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 50)}"

HOSTNAME="${APP_NAME}.azurewebsites.net"

echo "==> Deploying to https://${HOSTNAME}"
echo "    Resource group: ${RESOURCE_GROUP}  |  Location: ${LOCATION}"

# --- 1. Resource group -----------------------------------------------------
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

# --- 2. App Service plan: Linux, Free F1 tier ------------------------------
az appservice plan create \
  --name "$APP_PLAN" \
  --resource-group "$RESOURCE_GROUP" \
  --is-linux \
  --sku F1 \
  --output none

# --- 3. Web App on the Python 3.12 runtime ---------------------------------
az webapp create \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --plan "$APP_PLAN" \
  --runtime "PYTHON:${PYTHON_VERSION}" \
  --output none

# --- 4. Storage account + public blob container for media ------------------
az storage account create \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-blob-public-access true \
  --output none

STORAGE_KEY="$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query '[0].value' --output tsv)"

az storage container create \
  --name "$MEDIA_CONTAINER" \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --public-access blob \
  --output none

# --- 5. App settings (environment variables read by the Django app) --------
# Oryx builds the app and runs collectstatic when SCM_DO_BUILD_DURING_DEPLOYMENT
# is true. DATABASE_NAME points SQLite at the persistent /home volume.
az webapp config appsettings set \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --settings \
    DJANGO_SETTINGS_MODULE="bakerydemo.settings.production" \
    DJANGO_SECRET_KEY="$DJANGO_SECRET_KEY" \
    DJANGO_ALLOWED_HOSTS="$HOSTNAME" \
    PRIMARY_HOST="$HOSTNAME" \
    DATABASE_NAME="/home/data/bakerydemo.sqlite3" \
    ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    AZURE_STORAGE_ACCOUNT_NAME="$STORAGE_ACCOUNT" \
    AZURE_STORAGE_ACCOUNT_KEY="$STORAGE_KEY" \
    AZURE_STORAGE_CONTAINER="$MEDIA_CONTAINER" \
    SECURE_HSTS_SECONDS="0" \
    SCM_DO_BUILD_DURING_DEPLOYMENT="true" \
  --output none

# --- 6. Startup command: migrate + (first boot) load data, then Gunicorn ---
az webapp config set \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --startup-file "deploy/azure-startup.sh" \
  --output none

# --- 7. Deploy the code (tracked files at HEAD; Oryx builds on the server) --
ZIP_PATH="$(mktemp -t bakerydemo-azure-XXXXXX.zip)"
trap 'rm -f "$ZIP_PATH"' EXIT
git archive --format=zip --output "$ZIP_PATH" HEAD

az webapp deploy \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --type zip \
  --src-path "$ZIP_PATH" \
  --output none

# --- Done ------------------------------------------------------------------
cat <<EOF

==> Deployment complete.
    Site:   https://${HOSTNAME}
    Admin:  https://${HOSTNAME}/admin/  (login: admin / ${ADMIN_PASSWORD})

    First boot loads the demo content and media, which can take a minute.
    Tail the logs with:
      az webapp log tail --name "${APP_NAME}" --resource-group "${RESOURCE_GROUP}"

    Delete everything (stops all charges) with:
      az group delete --name "${RESOURCE_GROUP}"
EOF
