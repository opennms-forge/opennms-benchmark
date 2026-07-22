#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Task 4.6: emit one run manifest per variant from RUN-TIME probes (never
# backfilled — a run without a run-time manifest is rerun, not patched), then
# validate against run-manifest.schema.json. IV: sut.config_delta.
set -euo pipefail

VARIANT="${VARIANT:?set VARIANT=variant-b-plugin or variant-c-painless}"
BASE_URL="${BASE_URL:-http://localhost:8980/opennms}"
ES_URL="${ES_URL:-http://localhost:9200}"
EXP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="$EXP_DIR/build/fixture-identity.json"
CORPUS="$EXP_DIR/build/corpus-identity.json"       # written after seed reconciliation (task 3.4)
PARAMS="$EXP_DIR/results/benchmark/$VARIANT/trial-params.json"  # written by run-trials.sh on a valid block
OUT="$EXP_DIR/results/benchmark/$VARIANT/run-manifest.json"
HORIZON_CTR="$(docker compose -f "$EXP_DIR/compose.yml" ps -q horizon)"

[ -f "$IDENTITY" ] || { echo "missing $IDENTITY — run bin/build-sut.sh first" >&2; exit 1; }
[ -f "$CORPUS" ]   || { echo "missing $CORPUS — seed + reconcile first (tasks 3.x)" >&2; exit 1; }
[ -f "$PARAMS" ]   || { echo "missing $PARAMS — run bin/run-trials.sh for $VARIANT first" >&2; exit 1; }

# --- run-time probes (measure.md table) --------------------------------------
VERSION="$(curl -su admin:admin "$BASE_URL/rest/info" | jq -r '.displayVersion // .version')"
JVM_CMDLINE="$(docker exec "$HORIZON_CTR" sh -c "ps -o args= -p 1 || cat /proc/1/cmdline | tr '\0' ' '")"
JVM_VERSION="$(docker exec "$HORIZON_CTR" java -version 2>&1 | head -1)"
# Heap/GC derived from the RUNNING process, never from config files (measure.md).
# A failed probe ABORTS: a sentinel value would compare equal across variants
# and pass the comparability gate on a control it never verified.
JVM_HEAP="$(grep -oE '\-Xms[^ ]+ \-Xmx[^ ]+' <<<"$JVM_CMDLINE" || true)"
JVM_GC="$(grep -oE '\-XX:\+Use[A-Za-z0-9]+GC' <<<"$JVM_CMDLINE" | head -1 || true)"
if [ -z "$JVM_HEAP" ] || [ -z "$JVM_GC" ]; then
  echo "ABORT: heap/GC probe failed on running cmdline: $JVM_CMDLINE" >&2
  echo "Fix the probe or the SUT and re-emit — never backfill." >&2
  exit 1
fi
# ES + drift plugin are declared controls with a documented fallback pair —
# record them so a mid-experiment fallback swap cannot pass the gate unnoticed.
ES_VERSION="$(curl -sf "$ES_URL/" | jq -r '.version.number')"
ES_PLUGINS="$(curl -sf "$ES_URL/_cat/plugins?h=component,version" | sort | tr '\n' ';')"
# Request cache MUST be disabled on the corpus for trials — identical repeated
# queries on a static index are otherwise served from the shard request cache
# (measured: 10.7s cold vs 0.04s cached). Recorded as a gated control.
ES_REQ_CACHE="$(curl -sf "$ES_URL/netflow-*/_settings?filter_path=*.settings.index.requests" | jq -c '[.[].settings.index.requests.cache.enable] | unique')"
DB_VERSION="$(docker exec "$(docker compose -f "$EXP_DIR/compose.yml" ps -q database)" \
  psql -U postgres -tAc 'SELECT version()')"
TSS_BACKEND="$(docker exec "$HORIZON_CTR" sh -c \
  "grep -h '^org.opennms.timeseries.strategy' /opt/opennms/etc/opennms.properties* 2>/dev/null | tail -1" \
  || echo 'org.opennms.timeseries.strategy=rrd (default)')"
# The IV is ONLY the proportionalSumStrategy line; it goes into config_delta,
# which the gate exempts as the declared IV. Everything ELSE in the overlay is
# a control, so its hash lives in sut.overlay_sha — a gated comparability path
# (an exempted config_delta could never catch a stray control-file difference).
# The hash strips the IV line, so byte-identical controls give the SAME sha on
# both variants: dotfiles excluded, C collation, filenames included.
OVERLAY_DIR="$EXP_DIR/variants/$VARIANT"
STRATEGY="$(grep -o 'proportionalSumStrategy=.*' \
  "$OVERLAY_DIR/org.opennms.features.flows.persistence.elastic.cfg")"
OVERLAY_SHA="$(cd "$OVERLAY_DIR" && LC_ALL=C find . -type f -not -name '.*' | LC_ALL=C sort | \
  while read -r f; do
    printf '== %s\n' "$f"
    grep -v '^proportionalSumStrategy=' "$f" || true
  done | shasum -a 256 | awk '{print $1}')"
CONFIG_DELTA="overlay $VARIANT: $STRATEGY"

case "$(uname)" in
  Darwin) CPU="$(sysctl -n machdep.cpu.brand_string) ($(sysctl -n hw.ncpu) cores)"
          RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ));;
  *)      CPU="$(lscpu | awk -F': +' '/Model name/{print $2}') ($(nproc) cores)"
          RAM_GB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1048576 ));;
esac

NL6_VERSION="$(docker inspect --format '{{index .RepoDigests 0}}' \
  "$(docker compose -f "$EXP_DIR/compose.yml" ps -q nl6 2>/dev/null || true)" 2>/dev/null \
  || echo 'nl6 not running — copy generator_version from the seed record')"

jq -n \
  --arg variant "$VARIANT" \
  --arg version "$VERSION" \
  --arg jvm_version "$JVM_VERSION" \
  --arg jvm_cmdline "$JVM_CMDLINE" \
  --arg jvm_heap "$JVM_HEAP" \
  --arg jvm_gc "$JVM_GC" \
  --arg es_version "$ES_VERSION" \
  --arg es_plugins "$ES_PLUGINS" \
  --arg es_req_cache "$ES_REQ_CACHE" \
  --arg db "$DB_VERSION" \
  --arg tss "$TSS_BACKEND" \
  --arg config_delta "$CONFIG_DELTA" \
  --arg overlay_sha "$OVERLAY_SHA" \
  --arg cpu "$CPU" --argjson ram "$RAM_GB" --arg os "$(uname -srm)" \
  --arg nl6 "$NL6_VERSION" \
  --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --slurpfile fixture "$IDENTITY" \
  --slurpfile corpus "$CORPUS" \
  --slurpfile params "$PARAMS" \
  '{
    experiment: {
      question: "Does replacing the elasticsearch-drift-plugin proportional_sum aggregation with inline Painless scripts (PR #8638 / NMS-20027) regress netflow query performance?",
      independent_variable: "sut.config_delta",
      variant: $variant
    },
    sut: {
      version_identity: { version: $version, git_sha: $fixture[0].git_sha,
                          image_digest: $fixture[0].image_digest,
                          tarball_sha256: $fixture[0].tarball_sha256 },
      jvm: { version: $jvm_version,
             heap: $jvm_heap, gc: $jvm_gc, flags: $jvm_cmdline },
      elasticsearch: { version: $es_version, plugins: $es_plugins, request_cache: $es_req_cache },
      db_version: $db,
      tss_backend: $tss,
      config_delta: $config_delta,
      overlay_sha: $overlay_sha,
      provisioner: "container-branch"
    },
    host: { cpu: $cpu, ram_gb: $ram, disk: "nvme (laptop)", os: $os,
            generator_colocated: true,
            hygiene_notes: "laptop scope: governor/turbo not pinned; Docker VM net.core.rmem_max=64MB (non-persistent sysctl); relative A/B only" },
    workload: {
      axis: "rest-ui",
      generator_scenario: "queries/queries.json (fixed order, trial 1 discarded)",
      generator_version: "curl (trial runner) / seed: \($nl6)",
      parameters: $params[0],
      fixtures: [
        { name: "sut-image", identity: $fixture[0].image_digest },
        { name: "assembly-tarball", identity: $fixture[0].tarball_sha256 },
        { name: "flow-corpus", identity: ($corpus[0] | tostring) }
      ]
    },
    run: { id: "\($variant)-\($started)", started_at: $started },
    comparability_key: [
      "sut.version_identity",
      "sut.jvm.heap",
      "sut.jvm.gc",
      "sut.elasticsearch",
      "sut.db_version",
      "sut.tss_backend",
      "sut.config_delta",
      "sut.overlay_sha",
      "host.cpu",
      "host.ram_gb",
      "host.disk",
      "host.generator_colocated",
      "workload.axis",
      "workload.generator_scenario",
      "workload.generator_version",
      "workload.parameters",
      "workload.fixtures"
    ]
  }' > "$OUT"

npx --yes ajv-cli validate --spec=draft2020 \
  -s "$EXP_DIR/run-manifest.schema.json" -d "$OUT"
echo "manifest emitted + validated: $OUT"
