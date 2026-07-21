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
OUT="$EXP_DIR/results/$VARIANT/run-manifest.json"
HORIZON_CTR="$(docker compose -f "$EXP_DIR/compose.yml" ps -q horizon)"

[ -f "$IDENTITY" ] || { echo "missing $IDENTITY — run bin/build-sut.sh first" >&2; exit 1; }
[ -f "$CORPUS" ]   || { echo "missing $CORPUS — seed + reconcile first (tasks 3.x)" >&2; exit 1; }

# --- run-time probes (measure.md table) --------------------------------------
VERSION="$(curl -su admin:admin "$BASE_URL/rest/info" | jq -r '.displayVersion // .version')"
JVM_CMDLINE="$(docker exec "$HORIZON_CTR" sh -c "ps -o args= -p 1 || cat /proc/1/cmdline | tr '\0' ' '")"
JVM_VERSION="$(docker exec "$HORIZON_CTR" java -version 2>&1 | head -1)"
# Heap/GC derived from the RUNNING process, never from config files (measure.md).
JVM_HEAP="$(grep -oE '\-Xms[^ ]+ \-Xmx[^ ]+' <<<"$JVM_CMDLINE" || echo 'PROBE FAILED — rerun, do not backfill')"
JVM_GC="$(grep -oE '\-XX:\+Use[A-Za-z0-9]+GC' <<<"$JVM_CMDLINE" | head -1 || echo 'PROBE FAILED — rerun, do not backfill')"
# ES + drift plugin are declared controls with a documented fallback pair —
# record them so a mid-experiment fallback swap cannot pass the gate unnoticed.
ES_VERSION="$(curl -sf "$ES_URL/" | jq -r '.version.number')"
ES_PLUGINS="$(curl -sf "$ES_URL/_cat/plugins?h=component,version" | sort | tr '\n' ';')"
DB_VERSION="$(docker exec "$(docker compose -f "$EXP_DIR/compose.yml" ps -q database)" \
  psql -U postgres -tAc 'SELECT version()')"
TSS_BACKEND="$(docker exec "$HORIZON_CTR" sh -c \
  "grep -h '^org.opennms.timeseries.strategy' /opt/opennms/etc/opennms.properties* 2>/dev/null | tail -1" \
  || echo 'org.opennms.timeseries.strategy=rrd (default)')"
CONFIG_DELTA="overlay $VARIANT: $(shasum -a 256 "$EXP_DIR/variants/$VARIANT/org.opennms.features.flows.persistence.elastic.cfg" | awk '{print $1}') proportionalSumStrategy=$(grep -o 'proportionalSumStrategy=.*' "$EXP_DIR/variants/$VARIANT/org.opennms.features.flows.persistence.elastic.cfg")"

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
  --arg db "$DB_VERSION" \
  --arg tss "$TSS_BACKEND" \
  --arg config_delta "$CONFIG_DELTA" \
  --arg cpu "$CPU" --argjson ram "$RAM_GB" --arg os "$(uname -srm)" \
  --arg nl6 "$NL6_VERSION" \
  --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --slurpfile fixture "$IDENTITY" \
  --slurpfile corpus "$CORPUS" \
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
      elasticsearch: { version: $es_version, plugins: $es_plugins },
      db_version: $db,
      tss_backend: $tss,
      config_delta: $config_delta,
      provisioner: "container-branch"
    },
    host: { cpu: $cpu, ram_gb: $ram, disk: "nvme (laptop)", os: $os,
            generator_colocated: true,
            hygiene_notes: "laptop scope: governor/turbo not pinned; relative A/B only" },
    workload: {
      axis: "rest-ui",
      generator_scenario: "queries/queries.json (6 trials x dense+sparse, fixed order, trial 1 discarded)",
      generator_version: "curl (trial runner) / seed: \($nl6)",
      parameters: { trials: 6, shapes: ["dense", "sparse"], warmup_discarded: 1 },
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
