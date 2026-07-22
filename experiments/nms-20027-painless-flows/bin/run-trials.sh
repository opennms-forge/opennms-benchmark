#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Task 4.2: trial runner. 6 trials x 2 shapes in the fixed order of
# queries/queries.json; every raw response persisted (status/body/timing) keyed
# by variant/shape/trial. Doc-count guard before/after the block aborts on any
# corpus mutation (spec: corpus-seed). Trial 1 is warmup — persisted but marked
# discarded; statistics use trials 2-6 only (computed later, task 5.1).
set -euo pipefail

VARIANT="${VARIANT:?set VARIANT=variant-b-plugin or variant-c-painless}"
BASE_URL="${BASE_URL:-http://localhost:8980/opennms}"
ES_URL="${ES_URL:-http://localhost:9200}"
TRIALS="${TRIALS:-6}"

EXP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QUERIES="$EXP_DIR/queries/queries.json"
CORPUS_ID="$EXP_DIR/build/corpus-identity.json"
OUT="$EXP_DIR/results/$VARIANT"
mkdir -p "$OUT"

[ -f "$CORPUS_ID" ] || { echo "missing $CORPUS_ID — seed + reconcile first (tasks 3.x)" >&2; exit 1; }
# corpus-identity.json contract (written by the seed step, task 3.4 — see README):
#   { "doc_count": <n>, "window_start_ms": <T0>, "window_end_ms": <T1> }
# The query window comes from HERE, not from env — the seeded window is the
# only window the corpus can answer for; a hand-typed one can silently miss it.
EXPECTED_COUNT="$(jq -r '.doc_count' "$CORPUS_ID")"
T0="$(jq -r '.window_start_ms' "$CORPUS_ID")"
T1="$(jq -r '.window_end_ms' "$CORPUS_ID")"
case "$EXPECTED_COUNT/$T0/$T1" in *null*)
  echo "ABORT: $CORPUS_ID must contain doc_count, window_start_ms, window_end_ms (got: $(cat "$CORPUS_ID"))" >&2
  exit 1;;
esac

# Never let a stale run record survive an aborted re-run of this variant.
rm -f "$OUT/trial-params.json"
QUERIES_SHA="$(shasum -a 256 "$QUERIES" | awk '{print $1}')"

# Bucket counts pin the code paths (DENSE_BUCKET_LIMIT=4096 in the PR):
# 288 buckets -> dense, 6000 -> sparse. Steps floor at 1ms.
STEP_DENSE=$(( (T1 - T0) / 288 )); [ "$STEP_DENSE" -ge 1 ] || STEP_DENSE=1
STEP_SPARSE=$(( (T1 - T0) / 6000 )); [ "$STEP_SPARSE" -ge 1 ] || STEP_SPARSE=1

doc_count() { curl -sf "$ES_URL/netflow-*/_count" | jq -r '.count'; }

PRE_COUNT="$(doc_count)"
echo "$PRE_COUNT" > "$OUT/doc-count.pre"
if [ "$PRE_COUNT" != "$EXPECTED_COUNT" ]; then
  echo "ABORT: corpus doc count $PRE_COUNT != seeded count $EXPECTED_COUNT (corpus-identity.json) — corpus lost or mutated" >&2
  exit 1
fi
echo "corpus doc count (pre): $PRE_COUNT (matches seeded identity)"

jq -c '.queries[]' "$QUERIES" | while read -r q; do
  shape="$(jq -r '.shape' <<<"$q")"
  name="$(jq -r '.name' <<<"$q")"
  path="$(jq -r '.path' <<<"$q")"
  path="${path//\$\{T0\}/$T0}"
  path="${path//\$\{T1\}/$T1}"
  path="${path//\$\{STEP_DENSE\}/$STEP_DENSE}"
  path="${path//\$\{STEP_SPARSE\}/$STEP_SPARSE}"

  qdir="$OUT/$shape/$name"
  mkdir -p "$qdir"
  for trial in $(seq 1 "$TRIALS"); do
    body="$qdir/trial-$trial.body.json"
    status_time="$(curl -su admin:admin -o "$body" \
      -w '%{http_code} %{time_total}' "$BASE_URL$path")"
    status="${status_time% *}"
    time_total="${status_time#* }"
    [ "$status" = "200" ] || { echo "ABORT: $name trial $trial returned HTTP $status" >&2; exit 1; }
    jq -n --arg variant "$VARIANT" --arg shape "$shape" --arg name "$name" \
          --arg path "$path" --argjson trial "$trial" \
          --argjson status "$status" --argjson time_total_s "$time_total" \
          --argjson discarded "$([ "$trial" -eq 1 ] && echo true || echo false)" \
      '{variant:$variant, shape:$shape, name:$name, path:$path, trial:$trial,
        status:$status, time_total_s:$time_total_s, warmup_discarded:$discarded}' \
      > "$qdir/trial-$trial.meta.json"
    echo "$VARIANT $shape/$name trial $trial: ${time_total}s"
  done
done

POST_COUNT="$(doc_count)"
echo "$POST_COUNT" > "$OUT/doc-count.post"
if [ "$PRE_COUNT" != "$POST_COUNT" ]; then
  echo "ABORT: corpus mutated during trials ($PRE_COUNT -> $POST_COUNT) — block results are invalid" >&2
  exit 1
fi

# Run record of what ACTUALLY executed — emit-manifest.sh embeds this as
# workload.parameters so mismatched windows/trial counts fail the gate.
jq -n --argjson trials "$TRIALS" \
      --argjson window_start_ms "$T0" --argjson window_end_ms "$T1" \
      --argjson shapes "$(jq '[.queries[].shape] | unique' "$QUERIES")" \
      --arg queries_sha256 "$QUERIES_SHA" \
  '{trials: $trials, window_start_ms: $window_start_ms, window_end_ms: $window_end_ms,
    shapes: $shapes, queries_sha256: $queries_sha256, warmup_discarded: 1}' > "$OUT/trial-params.json"

echo "corpus doc count stable ($POST_COUNT) — block valid, results in $OUT"
