#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Tasks 3.2-3.4: drive one nl6 IPFIX loadtest scenario (create -> arm -> start
# -> report), reconcile the send ledger against Elasticsearch, and write
# build/corpus-identity.json. CALIBRATE=1 runs the same path but skips the
# identity write (used to establish the records-per-event ratio first).
#
# Env: DEVICES (default 200), RATE per device/s (default 25), WINDOW (default
# 8000s), DRAIN (default 30s), TOLERANCE_PCT accepted-vs-sent (default 99.5).
set -euo pipefail

DEVICES="${DEVICES:-200}"
RATE="${RATE:-25}"
WINDOW="${WINDOW:-8000s}"
DRAIN="${DRAIN:-30s}"
TOLERANCE_PCT="${TOLERANCE_PCT:-99.5}"
CALIBRATE="${CALIBRATE:-0}"
NL6_API="${NL6_API:-http://localhost:8081/api/v1}"
ES_URL="${ES_URL:-http://localhost:9200}"

EXP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$EXP_DIR/build"

es_count() { curl -sf "$ES_URL/netflow-*/_count" | jq -r '.count' || echo 0; }

PARTICIPANTS="$(jq -n --argjson n "$DEVICES" '[range($n) | "10.42.0.\(. + 1)"]')"
PRE_COUNT="$(es_count)"

SCENARIO="$(jq -n --argjson participants "$PARTICIPANTS" \
  --arg protocol ipfix --argjson rate "$RATE" --arg window "$WINDOW" --arg drain "$DRAIN" \
  '{participants: $participants, protocol: $protocol, rate: $rate,
    window: $window, drain: $drain, seed: 42}')"

ID="$(curl -sf -X POST -H 'Content-Type: application/json' -d "$SCENARIO" \
  "$NL6_API/scenarios" | jq -r '.id')"
echo "scenario $ID created ($DEVICES devices x $RATE/s x $WINDOW)"

ARMED="$(curl -sf -X POST "$NL6_API/scenarios/$ID/arm" | jq -r '.participants_armed')"
[ "$ARMED" = "$DEVICES" ] || { echo "ABORT: armed $ARMED of $DEVICES participants" >&2; exit 1; }

curl -sf -X POST "$NL6_API/scenarios/$ID/start" > /dev/null
echo "scenario $ID started"

while :; do
  PHASE="$(curl -sf "$NL6_API/scenarios/$ID" | jq -r '.phase')"
  case "$PHASE" in
    completed|finished|done|reported) break;;
    failed|aborted) echo "ABORT: scenario phase=$PHASE" >&2; exit 1;;
  esac
  sleep 30
done

REPORT="$EXP_DIR/build/seed-report-$ID.json"
curl -sf "$NL6_API/scenarios/$ID/report" > "$REPORT"

SENT="$(jq '[.. | objects | select(has("sent")) | .sent] | add' "$REPORT")"
FAILURES="$(jq '[.. | objects | select(has("send_failures")) | .send_failures] | add' "$REPORT")"
DROPPED="$(jq '[.. | objects | select(has("dropped")) | .dropped] | add' "$REPORT")"
if [ "${FAILURES:-0}" != "0" ] || [ "${DROPPED:-0}" != "0" ]; then
  echo "ABORT: generator was the bottleneck (send_failures=$FAILURES dropped=$DROPPED) — rerun lower" >&2
  exit 1
fi

# ES refresh so the count is final, then reconcile delivered vs accepted.
curl -sf -X POST "$ES_URL/netflow-*/_refresh" > /dev/null || true
POST_COUNT="$(es_count)"
ACCEPTED=$((POST_COUNT - PRE_COUNT))
RATIO="$(jq -n --argjson a "$ACCEPTED" --argjson s "$SENT" '($a / $s * 100 * 100 | round) / 100')"
echo "ledger sent=$SENT accepted=$ACCEPTED (records/event ratio incl. loss: ${RATIO}%)"

if [ "$CALIBRATE" = "1" ]; then
  echo "CALIBRATION ONLY — no corpus-identity written. Report: $REPORT"
  exit 0
fi

OK="$(jq -n --argjson a "$ACCEPTED" --argjson s "$SENT" --argjson t "$TOLERANCE_PCT" \
  '($a >= ($s * $t / 100)) and ($a <= ($s * (200 - $t) / 100))')"
if [ "$OK" != "true" ]; then
  echo "ABORT: accepted=$ACCEPTED outside tolerance ${TOLERANCE_PCT}% of sent=$SENT — corpus rejected" >&2
  exit 1
fi

T0_MS="$(jq -r '.t0' "$REPORT" | python3 -c 'import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.stdin.read().strip().replace("Z","+00:00")).timestamp()*1000))')"
T1_MS="$(jq -r '.t1' "$REPORT" | python3 -c 'import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.stdin.read().strip().replace("Z","+00:00")).timestamp()*1000))')"

jq -n --argjson doc_count "$POST_COUNT" \
      --argjson window_start_ms "$T0_MS" --argjson window_end_ms "$T1_MS" \
      --arg scenario_id "$ID" --arg report "$(basename "$REPORT")" \
  '{doc_count: $doc_count, window_start_ms: $window_start_ms, window_end_ms: $window_end_ms,
    scenario_id: $scenario_id, seed_report: $report}' > "$EXP_DIR/build/corpus-identity.json"

echo "corpus admitted — identity:"
cat "$EXP_DIR/build/corpus-identity.json"
