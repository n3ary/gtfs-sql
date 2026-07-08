#!/usr/bin/env bash
# firewall.sh -- apply the Hetzner Cloud Firewall for gtfs-rt.n3ary.com.
# Cloudflare's edge ranges change, so the script fetches them from
# https://api.cloudflare.com/client/v4/ips at run time instead of using a
# static CIDR list (which would go stale silently). Idempotent -- re-run to
# refresh CF ranges, or to rotate SSH_IP.

set -euo pipefail

: "${HCLOUD_SERVER_NAME:=ubuntu-4gb-nbg1-1}"
: "${HCLOUD_SERVER_ID:=}"
: "${SSH_IP:=78.97.175.93}"
: "${SSH_IP_2:=}"

command -v hcloud >/dev/null || { echo "hcloud CLI not installed" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not installed (apt-get install jq)" >&2; exit 1; }

FW_NAME="neary-gtfs-rt-01-edge-only"

cf_ips_json=$(curl -sSf https://api.cloudflare.com/client/v4/ips)
printf '%s' "$cf_ips_json" | jq -e '.success' >/dev/null || {
  echo "CF /ips API returned non-success" >&2
  echo "$cf_ips_json" | head -5 >&2
  exit 1
}
cf_ips=$(printf '%s' "$cf_ips_json" | jq -r '.result.ipv4_cidrs[], .result.ipv6_cidrs[]' | jq -R . | jq -s .)
echo "fetched $(printf '%s' "$cf_ips" | jq 'length') CF edge IP ranges (IPv4 + IPv6) from api.cloudflare.com/client/v4/ips"

if [ -z "$HCLOUD_SERVER_ID" ]; then
  HCLOUD_SERVER_ID=$(hcloud server list -o noheader -o columns=id,name | awk -v n="$HCLOUD_SERVER_NAME" '$2==n {print $1; exit}')
  [ -n "$HCLOUD_SERVER_ID" ] || { echo "server '$HCLOUD_SERVER_NAME' not found" >&2; exit 1; }
fi
echo "target server: $HCLOUD_SERVER_NAME (id $HCLOUD_SERVER_ID)"

# /32 hosts, not subnets -- only the operator's one or two SSH sources can reach :22.
ssh_sources=$(jq -nc --arg ip "$SSH_IP" --arg ip2 "$SSH_IP_2" \
  '$ip2 != "" | if . then [$ip, $ip2] else [$ip] end | map(. + "/32")')
echo "SSH source IPs (port 22): $(printf '%s' "$ssh_sources" | jq -c .)"

read -r -d '' RULES_JSON <<EOF
{
  "rules": [
    {
      "direction": "in", "protocol": "tcp", "port": "22",
      "source_ips": $(printf '%s' "$ssh_sources" | jq -c .),
      "description": "SSH from operator's home IP (rotate via SSH_IP=...)"
    },
    {
      "direction": "in", "protocol": "icmp",
      "source_ips": ["0.0.0.0/0", "::/0"],
      "description": "ICMP from anywhere"
    },
    {
      "direction": "in", "protocol": "tcp", "port": "80",
      "source_ips": $(printf '%s' "$cf_ips" | jq -c .),
      "description": "HTTP from CF edge (orange-cloud proxy)"
    },
    {
      "direction": "in", "protocol": "tcp", "port": "443",
      "source_ips": $(printf '%s' "$cf_ips" | jq -c .),
      "description": "HTTPS from CF edge (orange-cloud proxy)"
    },
    {
      "direction": "out", "protocol": "tcp", "port": "443",
      "destination_ips": ["0.0.0.0/0", "::/0"],
      "description": "outbound HTTPS (ghcr.io, apt)"
    },
    {
      "direction": "out", "protocol": "tcp", "port": "80",
      "destination_ips": ["0.0.0.0/0", "::/0"],
      "description": "outbound HTTP (apt redirects)"
    },
    {
      "direction": "out", "protocol": "udp", "port": "53",
      "destination_ips": ["0.0.0.0/0", "::/0"],
      "description": "outbound DNS"
    },
    {
      "direction": "out", "protocol": "icmp",
      "destination_ips": ["0.0.0.0/0", "::/0"],
      "description": "outbound ICMP"
    }
  ],
  "resources": [{"type": "server", "id": $HCLOUD_SERVER_ID}]
}
EOF

fw_id=$(hcloud firewall list -o noheader -o columns=id,name | awk -v n="$FW_NAME" '$2==n {print $1; exit}')

if [ -n "$fw_id" ]; then
  echo "firewall $FW_NAME exists (id $fw_id) - replacing rules and re-applying"
  printf '%s' "$RULES_JSON" | jq '.rules' | hcloud firewall replace-rules --rules-file /dev/stdin "$FW_NAME" >/dev/null
  hcloud firewall apply-to-resource --type server --server "$HCLOUD_SERVER_NAME" "$FW_NAME" >/dev/null
else
  echo "firewall $FW_NAME does not exist - creating + applying"
  printf '%s' "$RULES_JSON" | hcloud firewall create --name "$FW_NAME" --label "io.github.n3ary.component=gtfs-rt" --rules-file /dev/stdin >/dev/null
  hcloud firewall apply-to-resource --type server --server "$HCLOUD_SERVER_NAME" "$FW_NAME" >/dev/null
fi

echo "ok: $FW_NAME applied to $HCLOUD_SERVER_NAME (SSH restricted to $(printf '%s' "$ssh_sources" | jq 'length') IP(s))"
echo "verify: hcloud firewall describe $FW_NAME"
