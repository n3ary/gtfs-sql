#!/usr/bin/env bash
# install.sh -- bootstrap a fresh Hetzner CX23 to run @gtfs/rt under podman.
# The systemd unit does the runtime work; this script only installs the
# runtime + puts the unit + env in place. Idempotent.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
CONFIG_DIR="$REPO_ROOT/apps/gtfs-rt/config"
SYSTEMD_DIR="/etc/systemd/system"
ENV_DIR="/etc/neary-gtfs"
ENV_FILE="$ENV_DIR/rt.env"
SERVICE_FILE="$SYSTEMD_DIR/neary-gtfs-rt.service"
SERVICE_NAME="neary-gtfs-rt"

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
[ -f "$CONFIG_DIR/neary-gtfs-rt.service" ] || { echo "missing $CONFIG_DIR/neary-gtfs-rt.service" >&2; exit 1; }

cat <<'USAGE'
Prereqs: root, optionally GITHUB_TOKEN for private images.
After:   journalctl -u neary-gtfs-rt -f
         curl -sSf http://127.0.0.1/healthz
USAGE

apt-get update -qq
apt-get install -y -qq podman

useradd --system --no-create-home --shell /usr/sbin/nologin neary-gtfs 2>/dev/null || true
install -d -m 0750 -o neary-gtfs -g neary-gtfs "$ENV_DIR"
[ -f "$ENV_FILE" ] || install -m 0640 -o neary-gtfs -g neary-gtfs \
  "$CONFIG_DIR/rt.env.example" "$ENV_FILE"

install -m 0644 "$CONFIG_DIR/neary-gtfs-rt.service" "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

# Pre-login so the first podman pull inside ExecStart doesn't 401.
[ -n "${GITHUB_TOKEN:-}" ] && echo "$GITHUB_TOKEN" | podman login ghcr.io -u "${GITHUB_USER:-n3ary-ci}" --password-stdin

sleep 5
curl -sSf http://127.0.0.1/healthz >/dev/null \
  && echo "ok: /healthz responded on 127.0.0.1:80" \
  || { echo "warn: /healthz did not respond yet (the unit is still pulling/starting);"
       echo "       check 'journalctl -u $SERVICE_NAME -n 50'"; }

echo
echo "next steps:"
echo "  journalctl -u $SERVICE_NAME -f"
echo "  systemctl restart $SERVICE_NAME   # after a new image lands"
