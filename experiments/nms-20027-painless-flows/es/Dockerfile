# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Elasticsearch 8.18.2 with the OpenNMS drift plugin — used by BOTH variants
# (idle in variant C) so the cluster is byte-identical across the A/B.
# The plugin is version-locked: image and plugin MUST move together.
# Fallback pair (if the PR build fails the ES 8.18.2 smoke check):
#   FROM docker.elastic.co/elasticsearch/elasticsearch:7.17.13
#   ...download/v2.0.5_es-7.17.13/elasticsearch-drift-plugin-7.17.13-2.0.5.zip
FROM docker.elastic.co/elasticsearch/elasticsearch:8.18.2

RUN bin/elasticsearch-plugin install --batch \
    https://github.com/OpenNMS-Plugins/elasticsearch-drift-plugin/releases/download/v2.0.7_es-8.18.2/elasticsearch-drift-plugin-8.18.2-2.0.7.zip
