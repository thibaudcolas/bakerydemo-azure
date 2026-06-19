# Deploying bakerydemo to Azure App Service (Free F1)

A minimal, low-cost setup for trying the Wagtail bakerydemo on Azure. It runs on
the **free F1 App Service tier**, so the only thing you pay for is a few cents of
Blob Storage for uploaded media.

## What you get

| Concern | Choice | Cost |
| --- | --- | --- |
| Compute | App Service Linux **F1 (Free)**, Python 3.12, Gunicorn | **$0** |
| Database | SQLite on the App Service persistent `/home` volume | **$0** |
| Media | Azure Blob Storage (public container) | a few cents |
| Static files | WhiteNoise (served by the app) | $0 |
| Search | Wagtail database search backend | $0 |
| Cache | In-memory (locmem) | $0 |

There is no separate database, Redis, or Elasticsearch resource to pay for or
manage. The app is built on the server by Oryx from `requirements/production.txt`
— no Docker image or container registry is involved.

> **F1 tier limits:** ~60 CPU-minutes/day and no "always on", so the app sleeps
> when idle and the first request after a pause is slow. That is fine for a demo;
> upgrade the plan SKU (e.g. `B1`) for steady traffic.

## Deploy

```bash
az login
# from the repository root, with your changes committed:
./deploy/azure-deploy.sh
```

`APP_NAME` and `STORAGE_ACCOUNT` must be globally unique — override them (and
anything else) via environment variables:

```bash
APP_NAME=my-bakery STORAGE_ACCOUNT=mybakerymedia LOCATION=westeurope \
  ./deploy/azure-deploy.sh
```

The script is idempotent: re-run it to push a new version of the code (it deploys
the tracked files at `git archive HEAD`).

When it finishes it prints the site URL and the admin login (default
`admin` / `changeme` — set `ADMIN_PASSWORD` to change it).

## How it fits together

- **`azure-deploy.sh`** provisions the resource group, F1 plan, web app, and
  storage account/container, sets the app settings (environment variables), and
  deploys the code.
- **`azure-startup.sh`** is the App Service startup command. It applies
  migrations on every boot and loads the demo content + media + admin user once
  (guarded by a marker file on `/home`, so your admin edits survive restarts).
- **`bakerydemo/settings/production.py`** gains an Azure Blob media backend,
  activated by the `AZURE_STORAGE_ACCOUNT_NAME` app setting.

## Tear down

Deleting the resource group removes everything and stops all charges:

```bash
az group delete --name bakerydemo-rg
```
