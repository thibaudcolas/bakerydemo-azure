#!/usr/bin/env bash
#
# Startup command for the Azure App Service (Linux, Python) deployment.
#
# App Service runs this on every container start, from the app root
# (/home/site/wwwroot) with the Oryx-built virtualenv already on PATH.
#
#   * Migrations are idempotent, so we run them every boot.
#   * The demo content, media and admin user are loaded only ONCE, guarded by a
#     marker file on the persistent /home volume. This means edits you make in
#     the Wagtail admin survive restarts and redeploys (the SQLite database and
#     the marker both live under /home/data, which Azure persists).
#
# Configured as the startup file in deploy/azure-deploy.sh via:
#   az webapp config set --startup-file "deploy/azure-startup.sh"
set -euo pipefail

# Persistent, writable location for the SQLite database and the init marker.
# Must match DATABASE_NAME set in deploy/azure-deploy.sh.
DATA_DIR="/home/data"
mkdir -p "$DATA_DIR"

echo "[startup] Applying database migrations..."
python manage.py migrate --noinput

if [ ! -f "$DATA_DIR/.initialized" ]; then
  echo "[startup] First boot: loading demo content, media and admin user..."
  python manage.py load_initial_data
  python manage.py reset_admin_password
  touch "$DATA_DIR/.initialized"
else
  echo "[startup] Demo data already present; skipping load_initial_data."
fi

echo "[startup] Starting Gunicorn..."
exec gunicorn bakerydemo.wsgi \
  --bind=0.0.0.0:"${PORT:-8000}" \
  --workers=2 \
  --timeout=120
