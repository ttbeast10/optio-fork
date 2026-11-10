#!/usr/bin/env bash
# Install (or upgrade) Optio from an air-gap bundle. Run from the bundle
# directory on a machine that reaches the cluster. Needs kubectl and helm
# (tools/helm when the bundle was made --with-helm); nothing is downloaded.
#
#   ./deploy.sh [options]
#     --load <how>        where the cluster gets its images from:
#                           docker            the local Docker daemon (Docker Desktop
#                                             Kubernetes) — the default
#                           kind[:<name>]     load into a kind cluster
#                           k3d[:<name>]      import into a k3d cluster
#                           minikube          load into minikube
#                           registry:<prefix> push to a registry the cluster pulls
#                                             from, e.g. registry:registry.corp.local/optio
#                           none              the images are already there
#     --auth <mode>       disabled    no sign-in (rehearsal only) — the default
#                         setup-token real sign-in; the setup page is unlocked by a
#                                     one-time token this script prints
#     --public-url <url>  the URL browsers open (default http://localhost:30310)
#     --gitlab-hosts <l>  your GitLab servers, comma-separated (GITLAB_HOSTS), e.g.
#                         gitlab.corp.local,git.lab.local — also allowed outbound
#     --env <NAME=value>  any other API environment variable the chart has no value
#                         for (repeatable), e.g. GITLAB_OAUTH_BASE_URL=https://gitlab.corp.local
#     --pod-scope <s>     repo (default) | run: a pod per run for every repo
#     --namespace <ns>    default optio
#     --values <file>     extra chart values (repeatable), applied last — e.g. your
#                         sign-in provider, ingress, storage classes
#     --set <k=v>         extra helm --set (repeatable)
#     --dry-run           print the helm command, change nothing
set -euo pipefail

cd "$(dirname "$0")"
LOAD=docker
AUTH=disabled
PUBLIC_URL=http://localhost:30310
GITLAB_HOSTS=""
POD_SCOPE=""
NS=optio
EXTRA=()
ENVS=()
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --load) LOAD="${2:?}"; shift ;;
    --auth) AUTH="${2:?}"; shift ;;
    --public-url) PUBLIC_URL="${2:?}"; shift ;;
    --gitlab-hosts) GITLAB_HOSTS="${2:?}"; shift ;;
    --env) ENVS+=("${2:?}"); shift ;;
    --pod-scope) POD_SCOPE="${2:?}"; shift ;;
    --namespace) NS="${2:?}"; shift ;;
    --values) EXTRA+=(-f "${2:?}"); shift ;;
    --set) EXTRA+=(--set "${2:?}"); shift ;;
    --dry-run) DRY=1 ;;
    -h | --help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$AUTH" in disabled | setup-token) ;; *) echo "--auth is disabled or setup-token" >&2; exit 2 ;; esac
case "$POD_SCOPE" in "" | repo | run) ;; *) echo "--pod-scope is repo or run" >&2; exit 2 ;; esac

[ -x tools/helm ] && PATH="$PWD/tools:$PATH"
for tool in kubectl helm; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
rand() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

VERSION="$(sed -n 's/^version: *//p' BUNDLE.txt)"
IMAGES=()
while IFS= read -r img; do [ -z "$img" ] || IMAGES+=("$img"); done <images.txt

echo "== Checking the bundle"
sha -c SHA256SUMS >/dev/null || { echo "checksum mismatch: the bundle was changed or cut short" >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "kubectl cannot reach a cluster" >&2; exit 1; }
echo "   bundle $VERSION, cluster $(kubectl config current-context)"

need() { command -v "$1" >/dev/null || { echo "--load $LOAD needs $1 on this machine" >&2; exit 1; }; }
REGISTRY=""
if [ "$DRY" = 0 ]; then
  case "$LOAD" in
    none) ;;
    kind | kind:*) need docker; need kind ;;
    k3d | k3d:*) need docker; need k3d ;;
    minikube) need docker; need minikube ;;
    *) need docker ;;
  esac
  echo "== Loading images ($LOAD)"
  case "$LOAD" in
    none) ;;
    docker) gunzip -c images.tar.gz | docker load >/dev/null ;;
    kind | kind:*)
      gunzip -c images.tar.gz | docker load >/dev/null
      name="${LOAD#kind}"; name="${name#:}"
      kind load docker-image "${IMAGES[@]}" ${name:+--name "$name"}
      ;;
    k3d | k3d:*)
      gunzip -c images.tar.gz | docker load >/dev/null
      name="${LOAD#k3d}"; name="${name#:}"
      k3d image import "${IMAGES[@]}" ${name:+-c "$name"}
      ;;
    minikube)
      gunzip -c images.tar.gz | docker load >/dev/null
      for img in "${IMAGES[@]}"; do minikube image load "$img"; done
      ;;
    registry:*)
      REGISTRY="${LOAD#registry:}"; REGISTRY="${REGISTRY%/}"
      gunzip -c images.tar.gz | docker load >/dev/null
      for img in "${IMAGES[@]}"; do
        docker tag "$img" "$REGISTRY/$img"
        docker push "$REGISTRY/$img" >/dev/null
        echo "   pushed $REGISTRY/$img"
      done
      ;;
    *) echo "unknown --load $LOAD" >&2; exit 2 ;;
  esac
fi
case "$LOAD" in registry:*) REGISTRY="${LOAD#registry:}"; REGISTRY="${REGISTRY%/}" ;; esac

# Keys live in the cluster once installed; reuse them so an upgrade doesn't
# lock the database or the stored secrets.
secret() { kubectl get secret "$1" -n "$NS" -o "jsonpath={.data.$2}" 2>/dev/null | base64 -d 2>/dev/null || true; }
ENC_KEY="$(secret optio-config OPTIO_ENCRYPTION_KEY)"
[ -n "$ENC_KEY" ] || ENC_KEY="$(rand 32)"
PG_PASS="$(secret optio-postgres-credentials POSTGRES_PASSWORD)"
[ -n "$PG_PASS" ] || PG_PASS="$(rand 16)"

ARGS=(upgrade --install optio ./chart -n "$NS" --create-namespace
  -f values.airgap.yaml
  --set "api.image.tag=$VERSION" --set "web.image.tag=$VERSION" --set "agent.image.tag=$VERSION"
  --set "encryption.key=$ENC_KEY" --set "postgresql.auth.password=$PG_PASS"
  --set "publicUrl=$PUBLIC_URL" --set "namespace=$NS" --set createNamespace=false)
if [ -n "$REGISTRY" ]; then
  ARGS+=(--set "api.image.repository=$REGISTRY/optio-api" --set "web.image.repository=$REGISTRY/optio-web"
    --set "agent.image.repository=$REGISTRY/optio-base" --set "agent.image.prefix=$REGISTRY/optio-"
    --set "postgresql.image.repository=$REGISTRY/postgres" --set "redis.image.repository=$REGISTRY/redis")
else
  # Loaded straight into the node: never ask a registry.
  ARGS+=(--set api.image.pullPolicy=Never --set web.image.pullPolicy=Never
    --set agent.image.pullPolicy=Never --set agent.imagePullPolicy=Never)
fi
SETUP_TOKEN=""
if [ "$AUTH" = disabled ]; then
  ARGS+=(--set auth.disabled=true)
else
  SETUP_TOKEN="$(secret optio-config OPTIO_SETUP_TOKEN)"
  [ -n "$SETUP_TOKEN" ] || SETUP_TOKEN="$(rand 24)"
  ARGS+=(--set auth.disabled=false --set "auth.setupToken=$SETUP_TOKEN")
fi
[ -z "$POD_SCOPE" ] || ARGS+=(--set "agent.podScope=$POD_SCOPE")
# What the chart has no value for reaches the API through a Secret of our own
# (existingSecrets maps a key of it to an environment variable).
if [ -n "$GITLAB_HOSTS" ]; then
  ENVS+=("GITLAB_HOSTS=$GITLAB_HOSTS")
  # Let the API call those (private) hosts.
  ARGS+=(--set "outbound.allowedHosts={$GITLAB_HOSTS}")
fi
for pair in ${ENVS[@]+"${ENVS[@]}"}; do
  name="${pair%%=*}"
  case "$pair" in *=*) ;; *) echo "--env wants NAME=value, got $pair" >&2; exit 2 ;; esac
  ARGS+=(--set "existingSecrets.$name.name=optio-airgap-env" --set "existingSecrets.$name.key=$name")
done
ARGS+=(${EXTRA[@]+"${EXTRA[@]}"})

if [ "$DRY" = 1 ]; then
  printf 'helm'; printf ' %q' "${ARGS[@]}" | sed -e "s/$ENC_KEY/<encryption key>/" -e "s/$PG_PASS/<postgres password>/" -e "s/${SETUP_TOKEN:-@@none@@}/<setup token>/"; echo
  exit 0
fi

echo "== Installing"
kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS" >/dev/null
if [ "${#ENVS[@]}" -gt 0 ]; then
  literals=()
  for pair in "${ENVS[@]}"; do literals+=("--from-literal=$pair"); done
  kubectl create secret generic optio-airgap-env -n "$NS" "${literals[@]}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi
EXISTED=0
kubectl get deployment optio-api -n "$NS" >/dev/null 2>&1 && EXISTED=1
helm "${ARGS[@]}" >/dev/null
# A changed --env value lives in a Secret the Deployment only reads at start.
[ "$EXISTED" = 0 ] || [ "${#ENVS[@]}" = 0 ] || kubectl rollout restart deployment/optio-api -n "$NS" >/dev/null
echo "   waiting for the rollout (migrations run at boot)…"
kubectl rollout status deployment/optio-api -n "$NS" --timeout=300s

cat <<DONE

Optio $VERSION is up in namespace $NS.
  Web:  $PUBLIC_URL
  Next: ./check.sh${NS:+ --namespace $NS}        verify the install
DONE
if [ "$AUTH" = disabled ]; then
  echo "  Sign-in is OFF (rehearsal). The setup page asks for a git token and an agent key;"
  echo "  ./skip-setup.sh stores both without the wizard."
else
  echo "  Setup token (unlocks the setup page's Sign-in step, one time): $SETUP_TOKEN"
fi
