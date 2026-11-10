#!/usr/bin/env bash
# Build an air-gap bundle of THIS checkout: every image the chart runs, the
# chart, the values and the deploy / check scripts, in one directory you can
# carry across.
#
# Run on a machine WITH internet access and Docker, from anywhere in the repo:
#
#   deploy/airgap/bundle.sh [version] [options]     → release/optio-airgap-<version>/
#     --presets <list>   also build language preset agent images, comma-separated
#                        (node,python,go,rust,full,…). Default: none (base only)
#     --platform <p>     image platform, e.g. linux/amd64. Default: this machine's.
#                        Pass linux/amd64 when building on an ARM laptop for an
#                        x86 cluster (slow under emulation).
#     --agent-clis <l>   agent CLIs in the base image (default all), e.g. claude-code,opencode
#     --with-helm        include a helm binary (linux/amd64) in tools/
#     --out <dir>        another output directory
#     --no-build         don't build; bundle the optio-*:<version> images already here
#     --tar              also write <out>.tar (one file to copy)
#
# version defaults to `git describe --tags --always`.
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"
HERE="$ROOT/deploy/airgap"

VERSION=""
PRESETS=""
PLATFORM=""
AGENT_CLIS="all"
WITH_HELM=0
OUT=""
BUILD=1
MAKE_TAR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --presets) PRESETS="${2:?--presets needs a list}"; shift ;;
    --platform) PLATFORM="${2:?--platform needs a value}"; shift ;;
    --agent-clis) AGENT_CLIS="${2:?--agent-clis needs a list}"; shift ;;
    --with-helm) WITH_HELM=1 ;;
    --out) OUT="${2:?--out needs a directory}"; shift ;;
    --no-build) BUILD=0 ;;
    --tar) MAKE_TAR=1 ;;
    -h | --help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) VERSION="$1" ;;
  esac
  shift
done
[ -n "$VERSION" ] || VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
VERSION="${VERSION//\//-}"
[ -n "$OUT" ] || OUT="$ROOT/release/optio-airgap-$VERSION"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "the Docker daemon is not running" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

PLATFORM_ARGS=()
[ -z "$PLATFORM" ] || PLATFORM_ARGS=(--platform "$PLATFORM")

# The chart's pinned third-party images, re-tagged without the digest (see
# values.airgap.yaml), and the init containers' busybox.
pinned() { # <values key block> → repository:tag@digest from helm/optio/values.yaml
  awk -v block="$1:" '
    $0 == block { on = 1; next }
    on && /^[a-z]/ { on = 0 }
    on && /repository:/ { repo = $2 }
    on && /tag:/ { gsub(/"/, "", $2); print repo ":" $2; exit }' helm/optio/values.yaml
}
PG_REF="$(pinned postgresql)"
REDIS_REF="$(pinned redis)"
THIRD_PARTY=("$PG_REF postgres:16" "$REDIS_REF redis:7-alpine" "busybox:1.36 busybox:1.36")

OPTIO_IMAGES=("optio-api:$VERSION" "optio-web:$VERSION" "optio-base:$VERSION")
IFS=',' read -r -a PRESET_LIST <<<"$PRESETS"
for p in ${PRESET_LIST[@]+"${PRESET_LIST[@]}"}; do [ -z "$p" ] || OPTIO_IMAGES+=("optio-$p:$VERSION"); done

if [ "$BUILD" = 1 ]; then
  echo "== Building Optio $VERSION images ${PLATFORM:+for $PLATFORM}"
  docker build ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} --build-arg OPTIO_VERSION="$VERSION" \
    -t "optio-api:$VERSION" -f Dockerfile.api .
  # Vendored fonts: the web build fetches nothing from Google Fonts.
  docker build ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} --build-arg OPTIO_VERSION="$VERSION" \
    --build-arg OPTIO_OFFLINE_FONTS=1 -t "optio-web:$VERSION" -f Dockerfile.web .
  docker build ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} --build-arg AGENT_CLIS="$AGENT_CLIS" \
    -t "optio-base:$VERSION" -f images/base.Dockerfile .
  for p in ${PRESET_LIST[@]+"${PRESET_LIST[@]}"}; do
    [ -n "$p" ] || continue
    [ -f "images/$p.Dockerfile" ] || { echo "no such preset: $p (images/$p.Dockerfile)" >&2; exit 1; }
    docker build ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} --build-arg BASE_IMAGE="optio-base:$VERSION" \
      -t "optio-$p:$VERSION" -f "images/$p.Dockerfile" .
  done
fi
for img in "${OPTIO_IMAGES[@]}"; do
  docker image inspect "$img" >/dev/null 2>&1 || { echo "missing image $img" >&2; exit 1; }
done

echo "== Pulling the chart's third-party images"
SAVE=("${OPTIO_IMAGES[@]}")
for entry in "${THIRD_PARTY[@]}"; do
  ref="${entry% *}" tag="${entry#* }"
  docker pull ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} "$ref" >/dev/null
  # A digest-pinned pull is stored as name@digest; give it the plain tag.
  case "$ref" in
    *@*) docker tag "${ref%:*@*}@${ref#*@}" "$tag" ;;
    *) [ "$ref" = "$tag" ] || docker tag "$ref" "$tag" ;;
  esac
  SAVE+=("$tag")
done

echo "== Writing $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/tools"
docker save "${SAVE[@]}" | gzip >"$OUT/images.tar.gz"
printf '%s\n' "${SAVE[@]}" >"$OUT/images.txt"
cp -R helm/optio "$OUT/chart"
cp "$HERE/values.airgap.yaml" "$HERE/deploy.sh" "$HERE/check.sh" "$HERE/skip-setup.sh" "$HERE/README.md" "$OUT/"
chmod +x "$OUT"/*.sh

if [ "$WITH_HELM" = 1 ]; then
  # Same pin as scripts/offline/make-kit.sh.
  HELM_VERSION=v3.22.0
  HELM_SHA256=1e4ab49e429626cf6c6958d914248b78c9730803c2751b87627e171dc800e7bb
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/helm.tgz" "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz"
  echo "$HELM_SHA256  $tmp/helm.tgz" | sha -c - >/dev/null
  tar -xzf "$tmp/helm.tgz" -C "$tmp"
  cp "$tmp/linux-amd64/helm" "$OUT/tools/helm"
  rm -rf "$tmp"
fi

cat >"$OUT/BUNDLE.txt" <<META
Optio air-gap bundle
version:   $VERSION
revision:  $(git rev-parse HEAD 2>/dev/null || echo unknown)$(git diff --quiet 2>/dev/null || echo " (with uncommitted changes)")
branch:    $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
platform:  ${PLATFORM:-$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')}
agent CLIs: $AGENT_CLIS
built:     $(date -u +%Y-%m-%dT%H:%M:%SZ)
images:
$(sed 's/^/  /' "$OUT/images.txt")
META
(cd "$OUT" && find . -type f ! -name SHA256SUMS | sort | while IFS= read -r f; do sha "$f"; done >SHA256SUMS)

if [ "$MAKE_TAR" = 1 ]; then
  tar -C "$(dirname "$OUT")" -cf "$OUT.tar" "$(basename "$OUT")"
  echo "== $OUT.tar ($(du -h "$OUT.tar" | cut -f1))"
fi
echo "== Done: $OUT ($(du -sh "$OUT" | cut -f1))"
echo "   Carry it across, then: ./deploy.sh --help"
