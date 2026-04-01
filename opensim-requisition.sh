#!/usr/bin/env bash
# opensim-requisition.sh — generate and import an OpenNMS requisition from l8opensim devices
#
# Usage:
#   ./opensim-requisition.sh                  # generate XML to stdout
#   ./opensim-requisition.sh --import         # generate and import into OpenNMS
#   ./opensim-requisition.sh --import --dry-run  # print what would be imported
#
set -euo pipefail

OPENSIM_URL="${OPENSIM_URL:-https://bench-lab/opensim}"
OPENNMS_HOST="${OPENNMS_HOST:-192.0.2.197}"
OPENNMS_PORT="${OPENNMS_PORT:-8980}"
OPENNMS_USER="${OPENNMS_USER:-admin}"
OPENNMS_PASS="${OPENNMS_PASS:-admin}"
FOREIGN_SOURCE="${FOREIGN_SOURCE:-opensim-inventory}"
MINION_LOCATION="${MINION_LOCATION:-lab-location-01}"

IMPORT=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --import)   IMPORT=true; shift ;;
    --dry-run)  DRY_RUN=true; shift ;;
    *) echo "Error: unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── fetch devices ─────────────────────────────────────────────────────────────

devices_json=$(curl -sk "${OPENSIM_URL}/api/v1/devices")

if [[ $(echo "$devices_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['success'])") != "True" ]]; then
  echo "Error: l8opensim API returned an error" >&2
  echo "$devices_json" >&2
  exit 1
fi

# ── generate requisition XML ──────────────────────────────────────────────────

requisition=$(echo "$devices_json" | python3 - <<PYEOF
import sys, json
from datetime import datetime, timezone

data = json.load(sys.stdin)
devices = data["data"]

ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
foreign_source = "${FOREIGN_SOURCE}"
location = "${MINION_LOCATION}"

lines = []
lines.append('<?xml version="1.0" encoding="UTF-8"?>')
lines.append(f'<model-import xmlns="http://xmlns.opennms.org/xsd/config/model-import"')
lines.append(f'              date-stamp="{ts}"')
lines.append(f'              foreign-source="{foreign_source}">')

for device in devices:
    node_id = device["id"]
    ip      = device["ip"]
    lines.append(f'    <node location="{location}" foreign-id="{node_id}" node-label="{node_id}">')
    lines.append(f'        <interface ip-addr="{ip}" status="1" snmp-primary="P">')
    lines.append( '            <monitored-service service-name="ICMP"/>')
    lines.append( '            <monitored-service service-name="SNMP"/>')
    lines.append( '        </interface>')
    lines.append( '    </node>')

lines.append('</model-import>')
print("\n".join(lines))
PYEOF
)

# ── output or import ──────────────────────────────────────────────────────────

if ! $IMPORT; then
  echo "$requisition"
  exit 0
fi

node_count=$(echo "$requisition" | grep -c '<node ')
echo "Importing ${node_count} devices into OpenNMS as foreign-source '${FOREIGN_SOURCE}'..."

if $DRY_RUN; then
  echo "--- dry-run: requisition XML ---"
  echo "$requisition"
  exit 0
fi

opennms_base="http://${OPENNMS_HOST}:${OPENNMS_PORT}/opennms"
curl_opts=(-s -u "${OPENNMS_USER}:${OPENNMS_PASS}" -H "Content-Type: application/xml" -H "Accept: application/xml")

echo -n "Uploading requisition ... "
curl "${curl_opts[@]}" -X POST -d "$requisition" \
  "${opennms_base}/rest/requisitions"
echo "done"

echo -n "Triggering import      ... "
curl "${curl_opts[@]}" -X PUT \
  "${opennms_base}/rest/requisitions/${FOREIGN_SOURCE}/import?rescanExisting=false"
echo "done"
