#!/usr/bin/env bash
# HookPulse check-in for GitHub Actions. It reports how the job ended to POST /api/github/runs and proves which
# repository and workflow it runs in with the job's OIDC identity token, so it needs no secret. The first report
# creates the monitor with the workflow's schedule. It never breaks your job unless fail-on-error is true.
set -uo pipefail

resumo="${GITHUB_STEP_SUMMARY:-/dev/null}"
saida="${GITHUB_OUTPUT:-/dev/null}"

aviso() {
  echo "::warning title=HookPulse::$1"
  printf '### HookPulse\n\n%s\n' "$1" >> "$resumo"
  if [ "${HP_FAIL:-false}" = "true" ]; then exit 1; fi
  exit 0
}

case "${HP_STATUS:-}" in
  success | failure | cancelled) ;;
  *) aviso "Set \`status: \${{ job.status }}\` on the HookPulse step (got '${HP_STATUS:-}')." ;;
esac
if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  aviso "Add \`permissions: id-token: write\` to the workflow or the job, so the step can prove which repository it runs in."
fi

base="${HP_URL:-https://hookpulse.net}"
base="${base%/}"
umask 077
dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/hookpulse.XXXXXX")"
trap 'rm -rf "$dir"' EXIT

# 1. The job's identity token, issued for this address only.
if ! curl -fsS --max-time 15 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$base" -o "$dir/oidc.json"; then
  aviso "Could not get the GitHub identity token."
fi
token="$(sed -n 's/.*"value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$dir/oidc.json")"
[ -n "$token" ] || aviso "The GitHub identity token came empty."
echo "::add-mask::$token"
# Credentials go to curl through a file, never on its command line.
printf 'Authorization: Bearer %s\n' "$token" > "$dir/headers"
if [ -n "${HP_KEY:-}" ]; then
  echo "::add-mask::$HP_KEY"
  printf 'X-Ingest-Key: %s\n' "$HP_KEY" >> "$dir/headers"
fi

# 2. The report: strings escaped, numbers only when they are numbers.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
job="$(printf '%s' "${HP_JOB:-job}" | tr -c 'A-Za-z0-9_.-' '-' | cut -c1-64)"
corpo="{\"status\":\"$HP_STATUS\",\"job\":\"$(esc "$job")\""
if [ -n "${HP_SCHEDULE:-}" ]; then corpo="$corpo,\"schedule\":\"$(esc "$HP_SCHEDULE")\""; fi
if [[ "${HP_GRACE:-}" =~ ^[0-9]+$ ]]; then corpo="$corpo,\"grace_sec\":$HP_GRACE"; fi
if [[ "${HP_INTERVAL:-}" =~ ^[0-9]+$ ]]; then corpo="$corpo,\"interval_sec\":$HP_INTERVAL"; fi
if [ -n "${HP_ALERT_URL:-}" ]; then corpo="$corpo,\"alert_url\":\"$(esc "$HP_ALERT_URL")\""; fi
corpo="$corpo}"

# 3. Send it.
codigo="$(curl -sS --max-time 20 -X POST "$base/api/github/runs" -H @"$dir/headers" \
  -H 'content-type: application/json' -H 'user-agent: hookpulse-action/1' \
  --data "$corpo" -o "$dir/resposta.json" -w '%{http_code}')" || aviso "HookPulse did not answer ($base)."

# A field of the answer, by its dotted path; empty when absent.
campo() {
  if command -v jq > /dev/null 2>&1; then
    jq -r "$1 // empty" "$dir/resposta.json" 2> /dev/null
  elif command -v python3 > /dev/null 2>&1; then
    python3 - "$dir/resposta.json" "$1" << 'PY' 2> /dev/null
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].strip(".").split("."):
    d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else str(d).lower() if isinstance(d, bool) else d)
PY
  fi
}

if [ "$codigo" != "200" ]; then
  erro="$(campo .error)"
  case "$erro" in
    monitor_limit) aviso "This repository already has its free HookPulse monitors ($(campo .limit)). To add more, add your HookPulse setup key as the \`hookpulse-key\` secret: $base/pricing" ;;
    schedule_required) aviso "This run did not come from a schedule. Set \`interval-sec\`, or let a scheduled run create the monitor." ;;
    *) aviso "HookPulse answered HTTP $codigo${erro:+ ($erro)}." ;;
  esac
fi

nome="$(campo .monitor.name)"
estado="$(campo .monitor.state)"
cron="$(campo .monitor.cron)"
grace="$(campo .monitor.grace_sec)"
proximo="$(campo .monitor.next_expected_at)"
alerta="$(campo .monitor.alert)"
pagina="$(campo .monitor.status_page)"
badge="$(campo .monitor.badge)"
painel="$(campo .monitor.dashboard)"
ignorado="$(campo .ignored)"

{
  echo "### HookPulse"
  echo
  if [ "$(campo .created)" = "true" ]; then printf 'Monitor created for this job.\n\n'; fi
  if [ -n "$ignorado" ]; then printf 'A %s run records nothing: the next run that finishes counts.\n\n' "$ignorado"; fi
  echo "| | |"
  echo "|---|---|"
  echo "| Monitor | \`$nome\` |"
  echo "| State | $estado |"
  if [ -n "$cron" ] && [[ "$grace" =~ ^[0-9]+$ ]]; then
    echo "| Schedule | \`$cron\` (UTC), $((grace / 60)) min of allowed delay |"
  fi
  if [ -n "$proximo" ]; then echo "| Next run expected | $proximo |"; fi
  case "$alerta" in
    url) echo "| Alerts | your webhook |" ;;
    account_email) echo "| Alerts | your account's e-mail |" ;;
    *) echo "| Alerts | none yet: set \`alert-url\`, or add your setup key as the \`hookpulse-key\` secret |" ;;
  esac
  if [ -n "$pagina" ]; then echo "| Status page | $pagina |"; fi
  if [ -n "$painel" ]; then echo "| Dashboard | $painel |"; fi
  if [ -n "$badge" ]; then
    printf '\nREADME badge:\n\n```markdown\n[![HookPulse](%s)](%s)\n```\n' "$badge" "$pagina"
  fi
} >> "$resumo"
{
  echo "state=$estado"
  echo "status-page=$pagina"
  echo "badge=$badge"
} >> "$saida"
echo "HookPulse: $nome is $estado."
