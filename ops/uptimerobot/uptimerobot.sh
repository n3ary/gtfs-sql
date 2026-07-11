#!/usr/bin/env bash
# Setup script for the UptimeRobot backstop on gtfs-rt.n3ary.com.
#
# The uptime monitor inside GitHub Actions (workflows/uptime.yml)
# is the primary alert path: every 15 minutes it pings /healthz
# and the /api/rt/cluj-napoca/vehicle_positions endpoint, opens
# a GitHub issue on 3 consecutive failures, and reboots the VM.
# That catches every realistic failure mode of the service itself.
#
# What it does NOT catch: GitHub Actions itself being down (GH
# outage, runner quota exhausted, the user themselves
# disabling the workflow). When Actions is silent, there is no
# issue, no recovery, no human attention drawn to the service.
#
# UptimeRobot is the second-line monitor for that gap: an
# independent service, with its own cron, polling the same
# /healthz from a different IP. If both UptimeRobot and the GH
# cron go quiet, the user has bigger problems than uptime; if
# GH is silent but UptimeRobot is still polling, the email
# alert is enough for the user to act manually.
#
# This script is human-run, idempotent. It creates the monitor
# via UptimeRobot's REST API (api_key in macOS keychain under
# service=uptimerobot, account=mavis). Re-running is safe: if
# the monitor already exists, the script updates it.
#
# Required UptimeRobot setup (do this once, by hand):
#   1. Create an account at https://uptimerobot.com
#   2. Verify the email (UptimeRobot requires this before
#      accepting API calls)
#   3. Settings > API Settings > Monitor-specific API keys
#      (NOT the account-wide read-only key) - generate one
#   4. Stash the key: security add-generic-password \
#        -s uptimerobot -a mavis -w '<your-api-key>'
#   5. (Optional) Settings > Alert Contacts > add the email
#      you want failure notifications to land in
#   6. Run this script
#
# Manual trigger from the UI:
#   UptimeRobot dashboard > monitor row > "Check now" button
#   forces an immediate probe instead of waiting for the next
#   interval tick. Useful when the user is in the middle of a
#   deploy and wants to confirm the service is up before
#   declaring victory.
#
# Removing the monitor (if you stop using UptimeRobot):
#   Use the UptimeRobot UI, or pass --delete to this script.

set -euo pipefail

URL="https://gtfs-rt.n3ary.com/healthz"
INTERVAL=900   # 15 min - matches the GH Actions cron cadence
KEYWORD="ok"   # response body MUST contain "ok" to be UP
FRIENDLY="gtfs-rt"
API_BASE="https://api.uptimerobot.com/v2"

usage() {
  cat <<'USAGE'
Usage: uptimerobot.sh [--dry-run] [--delete]

  --dry-run   Show what would be created/updated, no API call.
  --delete    Delete the existing monitor (idempotent; no-op
              if no monitor matches).

Reads API key from the macOS keychain:
  service=uptimerobot, account=mavis
USAGE
  exit 1
}

DRY_RUN=0
DELETE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --delete)  DELETE=1 ;;
    -h|--help) usage ;;
    *) echo "unknown flag: $arg" >&2; usage ;;
  esac
done

API_KEY=$(security find-generic-password -s uptimerobot -a mavis -w 2>/dev/null || true)
if [ -z "${API_KEY:-}" ]; then
  echo "error: UptimeRobot API key not found in keychain" >&2
  echo "  stash it first:" >&2
  echo "    security add-generic-password -s uptimerobot -a mavis -w '<your-api-key>'" >&2
  echo "  (key type: monitor-specific, from uptimerobot.com Settings > API Settings)" >&2
  exit 1
fi

# Find existing monitor (idempotency: re-runs update the same monitor).
EXISTING_ID=$(curl -fsS -X POST "$API_BASE/getMonitors" \
  --data-urlencode "api_key=$API_KEY" \
  --data-urlencode "format=json" \
  --data-urlencode "search=$FRIENDLY" \
  | python3 -c "import json, sys; d = json.load(sys.stdin); ms = d.get('monitors', []); print(ms[0]['id'] if ms else '')" \
  2>/dev/null || echo "")

if [ "$DELETE" = "1" ]; then
  if [ -z "$EXISTING_ID" ]; then
    echo "no monitor named '$FRIENDLY' to delete"
    exit 0
  fi
  echo "deleting monitor id=$EXISTING_ID"
  if [ "$DRY_RUN" = "1" ]; then exit 0; fi
  curl -fsS -X POST "$API_BASE/deleteMonitor" \
    --data-urlencode "api_key=$API_KEY" \
    --data-urlencode "format=json" \
    --data-urlencode "id=$EXISTING_ID" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('stat:', d.get('stat'))
print('message:', d.get('error', {}).get('message', 'ok'))
"
  exit 0
fi

# Build the create-or-update call.
# UptimeRobot: type=1 is HTTP, type=2 is keyword, type=3 is ping
# keyword_type=1 means "alert if keyword IS NOT present" (so we
# fail when 'ok' is missing - this is the up signal).
PARAMS=(
  "api_key=$API_KEY"
  "format=json"
  "url=$URL"
  "type=1"
  "interval=$INTERVAL"
  "friendly_name=$FRIENDLY"
  "keyword_type=1"
  "keyword_value=$KEYWORD"
  "timeout=30"
)

if [ -n "$EXISTING_ID" ]; then
  PARAMS+=("id=$EXISTING_ID")
  ENDPOINT="editMonitor"
  ACTION="updating"
else
  ENDPOINT="newMonitor"
  ACTION="creating"
fi

echo "$ACTION monitor: $FRIENDLY"
echo "  url:      $URL"
echo "  interval: ${INTERVAL}s (15 min)"
echo "  keyword:  must contain '$KEYWORD' to count as UP"
echo "  timeout:  30s"
if [ -n "$EXISTING_ID" ]; then
  echo "  existing monitor id: $EXISTING_ID"
fi

if [ "$DRY_RUN" = "1" ]; then
  echo ""
  echo "dry run; would POST to $API_BASE/$ENDPOINT with:"
  printf '  %s\n' "${PARAMS[@]}"
  exit 0
fi

# Use --data-urlencode so the form is well-formed regardless of
# special characters in the URL / keyword.
RESPONSE=$(curl -fsS -X POST "$API_BASE/$ENDPOINT" \
  $(printf -- '--data-urlencode=%s ' "${PARAMS[@]}"))

echo ""
echo "$RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if d.get('stat') == 'ok':
    m = d.get('monitor', {})
    print('OK')
    print('  id:         ', m.get('id'))
    print('  url:        ', m.get('url'))
    print('  interval:   ', m.get('interval'))
    print('  status:     ', m.get('status'))  # 0=paused, 1=not checked yet, 2=up, 9=down
else:
    print('FAIL:', json.dumps(d.get('error', d)))
    sys.exit(1)
"
