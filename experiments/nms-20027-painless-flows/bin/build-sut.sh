#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Tasks 1.1-1.4: build the shared fixture ONCE — pinned checkout -> assembly
# tarball -> container image. Re-runs skip completed steps (shared-fixture rule:
# never rebuild an identical SHA). Identities land in build/fixture-identity.json.
set -euo pipefail

PINNED_SHA=03b6b6dd8cfb3d3b90094530d7b2d10439fe0a48
IMAGE_TAG="horizon-bench:${PINNED_SHA:0:8}"
EXP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$EXP_DIR/build}"
SRC_DIR="$BUILD_DIR/opennms"
IDENTITY="$BUILD_DIR/fixture-identity.json"

mkdir -p "$BUILD_DIR"

if [ -f "$IDENTITY" ]; then
  echo "HORIZON_IMAGE=$(jq -r '.image' "$IDENTITY")" > "$EXP_DIR/.env"
  echo "fixture-identity.json exists — fixture already built, reusing (task 1.4):"
  cat "$IDENTITY"
  exit 0
fi

# --- 1.1 pinned checkout + toolchain record ---------------------------------
if [ ! -d "$SRC_DIR/.git" ]; then
  git clone https://github.com/OpenNMS/opennms "$SRC_DIR"
fi
git -C "$SRC_DIR" fetch origin "$PINNED_SHA"
git -C "$SRC_DIR" checkout --detach "$PINNED_SHA"

JAVA_VERSION="$(java -version 2>&1 | head -1)"
MVN_VERSION="$( (cd "$SRC_DIR" && ./mvnw --version 2>/dev/null || mvn --version) | head -1)"
echo "toolchain: $JAVA_VERSION / $MVN_VERSION"

# --- 1.2 assembly tarball ----------------------------------------------------
# Exact invocation is defined by the checked-out branch (README/.circleci) —
# historically ./compile.pl then ./assemble.pl. Verify there before trusting this.
TARBALL="$(ls "$SRC_DIR"/opennms-full-assembly/target/*.tar.gz 2>/dev/null | head -1 || true)"
if [ -z "$TARBALL" ]; then
  (cd "$SRC_DIR" && ./compile.pl && ./assemble.pl -Dopennms.home=/opt/opennms)
  TARBALL="$(ls "$SRC_DIR"/opennms-full-assembly/target/*.tar.gz | head -1)"
fi
TARBALL_SHA256="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
echo "tarball: $TARBALL ($TARBALL_SHA256)"

# --- 1.3 container image from the tarball ------------------------------------
docker build -t "$IMAGE_TAG" "$SRC_DIR/opennms-container/core"
IMAGE_DIGEST="$(docker inspect --format '{{.Id}}' "$IMAGE_TAG")"

# --- record identities (feeds every run manifest) -----------------------------
jq -n \
  --arg sha "$PINNED_SHA" \
  --arg tarball "$(basename "$TARBALL")" \
  --arg tarball_sha256 "$TARBALL_SHA256" \
  --arg image "$IMAGE_TAG" \
  --arg image_digest "$IMAGE_DIGEST" \
  --arg java "$JAVA_VERSION" \
  --arg maven "$MVN_VERSION" \
  '{git_sha: $sha, tarball: $tarball, tarball_sha256: $tarball_sha256,
    image: $image, image_digest: $image_digest,
    toolchain: {java: $java, maven: $maven}}' > "$IDENTITY"

echo "HORIZON_IMAGE=$IMAGE_TAG" > "$EXP_DIR/.env"

echo "fixture built once — identity:"
cat "$IDENTITY"
