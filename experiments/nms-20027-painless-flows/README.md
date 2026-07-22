# NMS-20027: Painless proportional_sum vs. elasticsearch-drift-plugin

A/B benchmark of [OpenNMS PR #8638](https://github.com/OpenNMS/opennms/pull/8638) (NMS-20027):
does computing flow `proportional_sum` with inline Painless `scripted_metric` scripts regress
netflow query performance vs. the [elasticsearch-drift-plugin](https://github.com/OpenNMS-Plugins/elasticsearch-drift-plugin)?

Unlike the other directories under `experiments/`, this is **not** an Azure-lab Ansible
experiment — it is a local single-host container experiment (OpenNMS Core + PostgreSQL +
Elasticsearch + nl6 only; no Minion/Sentinel/Kafka). The full Stage-0 plan, design and task
list live in `openspec/changes/nms-20027-painless-flow-benchmark/`.

## Design in one paragraph

One build (OpenNMS/opennms @ `03b6b6dd8cfb3d3b90094530d7b2d10439fe0a48`), two variants that
differ in exactly one config line — `proportionalSumStrategy` in
`etc/org.opennms.features.flows.persistence.elastic.cfg`: **B** = `plugin` (drift plugin path),
**C** = `painless` (PR default). Elasticsearch 8.18.2 carries drift plugin `v2.0.7_es-8.18.2`
in *both* variants (idle in C) so the cluster is identical. A 40M-flow corpus is seeded once
via nl6 (send-ledger reconciled) and is read-only during trials. 6 trials × 2 query shapes
(dense whole-window / sparse fine-window) per variant; trial 1 discarded. The Painless path
intentionally fixes NMS-20001, so a B↔C correctness diff of series/totals is mandatory and is
reported next to the latency delta.

**Scope: relative A/B only.** Generator and SUT are co-located — no absolute flows/sec or QPS
figure from this experiment is valid.

## Layout

| Path | Purpose |
|---|---|
| `compose.yml` | The 4-service stack (database, horizon, elasticsearch, nl6) |
| `es/Dockerfile` | ES 8.18.2 + drift plugin `v2.0.7_es-8.18.2` |
| `variants/variant-b-plugin/` | etc-overlay for variant B (`proportionalSumStrategy=plugin`) |
| `variants/variant-c-painless/` | etc-overlay for variant C (`proportionalSumStrategy=painless`) |
| `scenarios/flow-seed.json` | nl6 IPFIX seed scenario: 5000 flows/s × 8000 s = 40M flows |
| `queries/queries.json` | The fixed query set (dense + sparse shapes) |
| `bin/build-sut.sh` | Tasks 1.1–1.4: pinned checkout → assembly tarball → image (skip-rebuild aware) |
| `bin/run-trials.sh` | Task 4.2: trial runner with doc-count guard and raw-response persistence |
| `bin/emit-manifest.sh` | Task 4.6: run-time manifest probes + schema validation |
| `run-manifest.schema.json` | Contract schema (copied from the opennms-benchmark skill) |
| `build/`, `results/` | Generated at run time — gitignored |

The two variant directories MUST stay byte-identical except the `proportionalSumStrategy`
line. Any additional config (e.g. enabling the telemetryd IPFIX listener) is applied to
*both* directories identically — it is a control and part of `config_delta`.

## Runbook (maps to `tasks.md`)

```sh
# 1. Build the shared fixture (~1–1.5 h once; re-runs skip)          [tasks 1.1–1.4]
./bin/build-sut.sh

# 2. Bring up variant B; verify plugin + smoke query                 [tasks 2.1–2.5]
#    (scoped service list: nl6's image is unpinned until step 3, and an
#     unpullable image aborts an unscoped `up` entirely)
VARIANT=variant-b-plugin docker compose up -d database elasticsearch horizon
curl -s localhost:9200/_cat/plugins            # drift plugin listed
curl -su admin:admin localhost:8980/opennms/rest/info   # version matches the SHA build

# 3. Seed the corpus once; reconcile ledger                          [tasks 3.1–3.4]
#    docker compose up -d nl6, then bin/seed-corpus.sh drives the scenario and
#    writes build/corpus-identity.json (doc_count + seeded window) itself.
#    MEASURED CONSTRAINTS (this host): flow volume is ~512 records/device/min
#    (the scenario 'rate' field is a no-op for flow protocols); end-to-end
#    ingest is ES-indexing-bound at ~1.7-1.8k docs/s with refresh disabled, so
#    DEVICES=200 matches the sink. Sizing: docs = devices x 512 x minutes
#    (1M ≈ 200 x 600s; 40M would be ~6.5 h). Wipe calibration debris first
#    (delete BY NAME — ES 8 rejects wildcard deletes):
#      curl -X DELETE "localhost:9200/$(curl -s 'localhost:9200/_cat/indices/netflow-*?h=index' | tr '\n' ',')"
DEVICES=200 WINDOW=600s ./bin/seed-corpus.sh

# 4. Trials (window + doc count are read from corpus-identity.json)  [tasks 4.1–4.6]
VARIANT=variant-b-plugin ./bin/run-trials.sh
VARIANT=variant-b-plugin ./bin/emit-manifest.sh
VARIANT=variant-c-painless docker compose up -d --force-recreate horizon   # flips the one line
VARIANT=variant-c-painless ./bin/run-trials.sh
VARIANT=variant-c-painless ./bin/emit-manifest.sh

# 5. Stats, correctness diff, report                                 [tasks 5.1–5.5]
#    Compute median/p95/min–max over trials 2–6; diff results/variant-b-plugin vs
#    results/variant-c-painless; splice runs+manifests JSON into the skill's
#    report-template.html (<script id="benchmark-data"> is the only edit).

# 6. Teardown                                                        [task 6.1]
docker compose down -v
```

**From-scratch reset** (rerun the experiment, or after re-pinning the SHA): the
named volumes and the host-side identity files have independent lifecycles and
MUST be cleared together, or the guards report contradictory states
("already built" vs. "corpus lost"):

```sh
docker compose down -v && rm -rf build/ results/ .env
```

## Verify-at-use gates (do not skip)

- **ES compatibility smoke check** (task 2.3): one flow query from the PR build against
  ES 8.18.2 before seeding. On failure: fall back to ES 7.17.13 + plugin `v2.0.5_es-7.17.13`
  (edit `es/Dockerfile`), same for both variants.
- **nl6 image + scenario flags** (task 3.1): pin a real nl6 release in `compose.yml`
  (`TODO-pin-release` placeholder fails the pull on purpose) and verify the scenario format
  against nl6 upstream docs; record the image digest as `workload.generator_version`.
- **Query-shape rendering** (task 4.1): on variant C confirm the dense query renders a
  `scripted_metric` *with* `nBuckets` and the sparse one *without* (enable Elastic query
  logging or inspect via ES slow log) before starting timed trials.
- **Disable the ES shard request cache before trials**
  (`PUT netflow-*/_settings {"index.requests.cache.enable": false}`): identical repeated
  queries on a static corpus are otherwise answered from the cache (measured 10.7 s cold
  vs 0.04 s cached — the trials would benchmark the cache). Probed into
  `sut.elasticsearch.request_cache` so the gate enforces it on both variants.
- **Seed rate re-budget** (task 3.2): resolved by calibration — ingest is ES-bound at
  ~1.2k docs/s at ES defaults (lossless after `net.core.rmem_max=64MB` in the Docker
  VM — a NON-PERSISTENT sysctl that must be re-applied after a VM restart:
  `docker run --rm --privileged --pid=host alpine nsenter -t 1 -m -u -n -i sysctl -w net.core.rmem_max=67108864`).
  Do NOT pre-create composable index templates for `netflow-*` to tune ingest: in
  ES 8 they REPLACE (not merge with) OpenNMS's legacy `netflow` template, the index
  is created with dynamic text mappings, and every flow aggregation then fails with
  a fielddata error — the corpus must be re-seeded. At 1M docs, defaults are fine.
