#!/usr/bin/env bash
# Verify an install made by deploy.sh: it runs, it runs only the bundle's
# images, the offline switches are on, and this build's features are there.
# Read-only except for one throwaway pod (the egress probe).
#
#   ./check.sh [--namespace optio] [--no-egress-probe]
set -uo pipefail

cd "$(dirname "$0")" || exit 1
NS=optio
PROBE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) NS="${2:?}"; shift ;;
    --no-egress-probe) PROBE=0 ;;
    -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

FAILED=0
ok() { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; FAILED=$((FAILED + 1)); }
note() { echo "  note  $*"; }
k() { kubectl -n "$NS" "$@"; }
# Run JavaScript in the API container (it has Node; the image has no curl).
api_js() { k exec deploy/optio-api -c api -- node -e "$1" 2>/dev/null; }
api_get() { api_js "fetch('http://127.0.0.1:'+(process.env.API_PORT||4000)+'$1').then(async r=>{process.stdout.write(r.status+' '+await r.text())}).catch(e=>{process.stdout.write('000 '+e.message)})"; }

echo "== Pods"
k rollout status deployment/optio-api --timeout=120s >/dev/null 2>&1 && ok "API + web deployment is rolled out" || bad "deployment/optio-api is not ready"
notready="$(k get pods --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed" {print $1 " (" $3 ")"}')"
[ -z "$notready" ] && ok "every pod is Running" || bad "pods not running: $(echo "$notready" | tr '\n' ' ')"
pulls="$(k get events --no-headers 2>/dev/null | grep -E 'ErrImagePull|ImagePullBackOff|Failed to pull' | head -3)"
[ -z "$pulls" ] && ok "no image pull failures" || bad "image pull failures: $pulls"

echo "== Images (all from the bundle)"
allowed="$(sed 's/:.*//; s|.*/||' images.txt | sort -u | tr '\n' ' ')"
while IFS= read -r img; do
  [ -n "$img" ] || continue
  base="${img%%@*}"; base="${base%:*}"; base="${base##*/}"
  case " $allowed " in *" $base "*) ok "$img" ;; *) bad "$img is not in the bundle" ;; esac
done < <(k get pods -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null | sort -u)

echo "== API"
health="$(api_get /api/health)"
case "$health" in 200*) ok "/api/health answers" ;; *) bad "/api/health: ${health:-no answer}" ;; esac
setup="$(api_get /api/setup/status)"
case "$setup" in
  *'"isSetUp":true'*) ok "setup is complete (no setup page)" ;;
  200*) note "setup page still shows: store a git token and an agent key (./skip-setup.sh)" ;;
  *) bad "/api/setup/status: ${setup:-no answer}" ;;
esac

echo "== Offline switches"
env_is() { # <container> <name> <expected>
  got="$(k exec deploy/optio-api -c "$1" -- printenv "$2" 2>/dev/null)"
  [ "$got" = "$3" ] && ok "$2=$3" || bad "$2 is '${got}' (want $3)"
}
env_is api OPTIO_UPDATE_CHECK false
env_is api OPTIO_AGENT_OFFLINE true
env_is web OPTIO_OFFLINE_UI true
scope="$(k exec deploy/optio-api -c api -- printenv OPTIO_POD_SCOPE 2>/dev/null)"
note "pod scope for repos without their own setting: ${scope:-repo}"
hosts="$(k exec deploy/optio-api -c api -- printenv GITLAB_HOSTS 2>/dev/null)"
note "GITLAB_HOSTS: ${hosts:-(not set: only gitlab.com and saved hosts are listed)}"

echo "== This build's features"
schema="$(api_get /api/config/schema.json)"
has() { case "$schema" in *"$1"*) ok "$2" ;; *) bad "$2 — not in this build" ;; esac; }
has '"podScope"' "pod scope (a pod per run) is in the Repo manifest schema"
has '"jenkinsJob"' "Jenkins as CI (repo jenkinsJob)"
has 'jenkins' "Jenkins trigger"
cols="$(k exec "$(k get pods -o name | grep postgres | head -1)" -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "select column_name from information_schema.columns where table_name='"'"'repos'"'"' and column_name in ('"'"'pod_scope'"'"','"'"'jenkins_job'"'"') order by 1"' 2>/dev/null | tr '\n' ' ')"
[ "$cols" = "jenkins_job pod_scope " ] && ok "migrations applied (repos.jenkins_job, repos.pod_scope)" || bad "repo columns missing (found: ${cols:-none})"
browse="$(api_get '/api/repos/browse?platform=gitlab')"
case "$browse" in
  200*'"hosts":['*) ok "GitLab server picker: $(echo "$browse" | sed -n 's/.*"hosts":\(\[[^]]*\]\).*/\1/p')" ;;
  401* | 403*) note "GitLab server picker needs a signed-in member (sign-in is on): check Repos → Add Repository → GitLab" ;;
  *) bad "/api/repos/browse: $(echo "$browse" | cut -c1-120)" ;;
esac

if [ "$PROBE" = 1 ]; then
  echo "== Egress (does this cluster behave like an air gap?)"
  out="$(k run optio-egress-probe --rm -i --restart=Never --image=busybox:1.36 --image-pull-policy=IfNotPresent \
    --quiet -- sh -c 'nc -z -w 4 1.1.1.1 443 && echo OPEN || echo CLOSED' 2>/dev/null | tail -1)"
  case "$out" in
    CLOSED) ok "pods cannot reach the internet" ;;
    OPEN) note "pods CAN reach the internet: this rehearsal won't catch a runtime download. Cut the network (or use an isolated cluster) to match the air gap" ;;
    *) note "egress probe did not run (${out:-no output})" ;;
  esac
fi

echo
[ "$FAILED" = 0 ] && echo "All checks passed." || { echo "$FAILED check(s) failed."; exit 1; }
