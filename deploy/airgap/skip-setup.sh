#!/usr/bin/env bash
# Get past the setup page without the wizard. Optio shows /setup until it has
# one git token and one agent credential stored (GET /api/setup/status); this
# stores them through the API, encrypted like any secret.
#
#   GITLAB_TOKEN=glpat-… ANTHROPIC_API_KEY=sk-… ./skip-setup.sh [--api http://localhost:30400]
#
# Values come from the environment, never the command line. Give at least one
# git token (GITLAB_TOKEN or GITHUB_TOKEN) and one agent credential
# (ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN, OPENAI_API_KEY, GEMINI_API_KEY or
# OPENCODE_DEFAULT_BASE_URL). A per-server GitLab token is any variable named
# GITLAB_TOKEN_<HOST>, e.g. GITLAB_TOKEN_GIT_LAB_LOCAL for git.lab.local.
#
# With sign-in on, also set OPTIO_TOKEN to a personal access token of an admin.
# For a rehearsal with no real services, any non-empty values get you past the
# page; agents and repo listing then fail until real ones replace them.
set -euo pipefail

API=http://localhost:30400
[ "${1:-}" != "--api" ] || API="${2:?--api needs a URL}"
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

NAMES=(GITLAB_TOKEN GITHUB_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY GEMINI_API_KEY OPENCODE_DEFAULT_BASE_URL)
while IFS= read -r name; do NAMES+=("$name"); done < <(compgen -e | grep '^GITLAB_TOKEN_' || true)

AUTH_HEADER=()
[ -z "${OPTIO_TOKEN:-}" ] || AUTH_HEADER=(-H "Authorization: Bearer $OPTIO_TOKEN")
json() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

stored=0
for name in "${NAMES[@]}"; do
  value="${!name:-}"
  [ -n "$value" ] || continue
  code="$(printf '{"name":"%s","value":"%s","scope":"global"}' "$name" "$(json "$value")" |
    curl -sS -o /dev/null -w '%{http_code}' -X POST "$API/api/secrets" \
      -H 'content-type: application/json' ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"} --data-binary @-)"
  case "$code" in
    2*) echo "stored $name"; stored=$((stored + 1)) ;;
    *) echo "could not store $name (HTTP $code)" >&2; exit 1 ;;
  esac
done
[ "$stored" -gt 0 ] || { echo "nothing to store: set GITLAB_TOKEN and an agent key in the environment" >&2; exit 1; }

if curl -sS "$API/api/setup/status" | grep -q '"isSetUp":true'; then
  echo "Setup is complete: open the web UI."
else
  echo "Stored, but setup still wants a git token AND an agent credential:"
  curl -sS "$API/api/setup/status"; echo
fi
