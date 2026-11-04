#!/usr/bin/env bash
# Structured logging for the CI scripts. Sourced by scripts/ci/lib.sh.
#
# Every message goes to two places:
#   console   one readable line:  <UTC time> <LEVEL> [<component>] message key=value
#             (on GitHub, warnings and errors also become annotations)
#   file      one JSON object per line in $FACTORY_LOG_DIR/events.jsonl, with
#             the correlation fields (run, job, image, version, target,
#             request ref) so a failure can be traced end to end
#
# Settings (environment):
#   FACTORY_LOG_LEVEL       debug | info | warn | error   (default info;
#                           debug when GitHub's "debug logging" is on)
#   FACTORY_LOG_DIR         where events.jsonl and other logs go
#                           (default build/logs)
#   FACTORY_LOG_COMPONENT   name shown in [brackets] (default: script name)
#   FACTORY_CORRELATION_ID  set once per run; defaults to the CI run id
#   REQUEST_REF             portal request (i<issue> / r<run>), when known
#
# See docs/logging.md.

if [[ -z "${FACTORY_LOG_LEVEL:-}" ]]; then
  if [[ "${RUNNER_DEBUG:-}" == "1" || "${CI_DEBUG_TRACE:-}" == "true" ]]; then
    FACTORY_LOG_LEVEL=debug
  else
    FACTORY_LOG_LEVEL=info
  fi
fi
export FACTORY_LOG_LEVEL
export FACTORY_LOG_DIR="${FACTORY_LOG_DIR:-build/logs}"
export FACTORY_CORRELATION_ID="${FACTORY_CORRELATION_ID:-${GITHUB_RUN_ID:+gh-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}}}"
FACTORY_CORRELATION_ID="${FACTORY_CORRELATION_ID:-${CI_PIPELINE_ID:+gl-${CI_PIPELINE_ID}}}"
FACTORY_CORRELATION_ID="${FACTORY_CORRELATION_ID:-local-$(date -u +%Y%m%dT%H%M%S)}"
FACTORY_LOG_COMPONENT="${FACTORY_LOG_COMPONENT:-$(basename "${0:-ci}" .sh)}"
mkdir -p "$FACTORY_LOG_DIR" 2> /dev/null || true

_log_level_num() {
  case "$1" in debug) echo 10 ;; info) echo 20 ;; warn) echo 30 ;; error) echo 40 ;; *) echo 20 ;; esac
}

factory_debug_enabled() { [[ "$FACTORY_LOG_LEVEL" == "debug" ]]; }

# _log_emit LEVEL MESSAGE [key=value ...]
_log_emit() {
  local level="$1" msg="$2" ts kv="" color reset=$'\033[0m'
  shift 2
  [[ "$(_log_level_num "$level")" -ge "$(_log_level_num "$FACTORY_LOG_LEVEL")" ]] || return 0
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local pair
  for pair in "$@"; do
    if [[ "$pair" == *" "* ]]; then kv+=" ${pair%%=*}=\"${pair#*=}\""; else kv+=" ${pair}"; fi
  done
  case "$level" in
    debug) color=$'\033[0;90m' ;; info) color=$'\033[1;34m' ;;
    warn) color=$'\033[1;33m' ;; error) color=$'\033[1;31m' ;;
  esac
  printf '%s%s %-5s [%s] %s%s%s\n' "$color" "$ts" "${level^^}" "$FACTORY_LOG_COMPONENT" "$msg" "$kv" "$reset" >&2

  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    case "$level" in
      warn) printf '::warning title=%s::%s\n' "$FACTORY_LOG_COMPONENT" "$msg" ;;
      error) printf '::error title=%s::%s\n' "$FACTORY_LOG_COMPONENT" "$msg" ;;
    esac
  fi

  # JSON line (jq does the escaping). Never let logging break the build.
  if command -v jq > /dev/null 2>&1; then
    local args=() k v
    for pair in "$@"; do
      k="${pair%%=*}"; v="${pair#*=}"
      args+=(--arg "$k" "$v")
    done
    jq -nc \
      --arg ts "$ts" --arg level "$level" --arg component "$FACTORY_LOG_COMPONENT" --arg msg "$msg" \
      --arg correlation_id "$FACTORY_CORRELATION_ID" \
      --arg run_id "${GITHUB_RUN_ID:-${CI_PIPELINE_ID:-}}" --arg job "${GITHUB_JOB:-${CI_JOB_NAME:-}}" \
      --arg image "${IMAGE_NAME:-}" --arg version "${IMAGE_VERSION:-}" --arg target "${TARGET:-}" \
      --arg request_ref "${REQUEST_REF:-}" \
      "${args[@]}" \
      '$ARGS.named' >> "${FACTORY_LOG_DIR}/events.jsonl" 2> /dev/null || true
  fi
}

log_debug() { _log_emit debug "$@"; }
log_info() { _log_emit info "$@"; }
log_warn() { _log_emit warn "$@"; }
log_error() { _log_emit error "$@"; }

# Collapsible section in the GitHub log; plain header elsewhere
log_group() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then printf '::group::%s\n' "$*"; else printf '==== %s\n' "$*" >&2; fi
}
log_group_end() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then printf '::endgroup::\n'; fi
}

# run_step NAME COMMAND...   Runs a command as a named, timed step.
# Writes step_start / step_end events (with duration and exit code) and
# returns the command's exit code, so callers decide what failure means.
run_step() {
  local name="$1" start rc
  shift
  start="$(date +%s)"
  log_info "step started: ${name}" event=step_start step="$name"
  log_debug "command: $*" step="$name"
  set +e
  "$@"
  rc=$?
  set -e
  local secs=$(($(date +%s) - start))
  if [[ $rc -eq 0 ]]; then
    log_info "step finished: ${name} (${secs}s)" event=step_end step="$name" rc=0 duration_s="$secs"
  else
    log_error "step failed: ${name} (exit ${rc} after ${secs}s)" event=step_end step="$name" rc="$rc" duration_s="$secs"
  fi
  return "$rc"
}

# Record who/what/where for this run in run-context.json (one per job).
write_run_context() {
  command -v jq > /dev/null 2>&1 || return 0
  local tools="{}" t v
  for t in packer terraform ansible syft grype crane az aws; do
    if command -v "$t" > /dev/null 2>&1; then
      v="$("$t" --version 2> /dev/null | head -1 | tr -d '\r')" || v=""
      tools="$(jq -c --arg k "$t" --arg v "$v" '. + {($k): $v}' <<< "$tools")"
    fi
  done
  jq -n \
    --arg correlation_id "$FACTORY_CORRELATION_ID" \
    --arg platform "$(if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then echo github; elif [[ "${GITLAB_CI:-}" == "true" ]]; then echo gitlab; else echo local; fi)" \
    --arg run_url "${GITHUB_SERVER_URL:+${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}}${CI_PIPELINE_URL:-}" \
    --arg sha "${GITHUB_SHA:-${CI_COMMIT_SHA:-}}" --arg ref "${GITHUB_REF:-${CI_COMMIT_REF_NAME:-}}" \
    --arg event "${GITHUB_EVENT_NAME:-${CI_PIPELINE_SOURCE:-}}" --arg actor "${GITHUB_ACTOR:-${GITLAB_USER_LOGIN:-}}" \
    --arg job "${GITHUB_JOB:-${CI_JOB_NAME:-}}" --arg runner "${RUNNER_NAME:-${CI_RUNNER_DESCRIPTION:-$(hostname)}}" \
    --arg image "${IMAGE_NAME:-}" --arg version "${IMAGE_VERSION:-}" --arg target "${TARGET:-}" \
    --arg request_ref "${REQUEST_REF:-}" --arg log_level "$FACTORY_LOG_LEVEL" \
    --argjson tools "$tools" \
    '$ARGS.named + {started_at: (now | todate)}' > "${FACTORY_LOG_DIR}/run-context.json" 2> /dev/null || true
  log_debug "run context written to ${FACTORY_LOG_DIR}/run-context.json"
}

# On failure: show where the job failed and a likely cause (scripts/ci/triage.py)
_log_on_err() {
  local rc=$? cmd="${BASH_COMMAND}" line="${BASH_LINENO[0]}" src="${BASH_SOURCE[1]:-$0}"
  log_error "command failed (exit ${rc}) at ${src}:${line}: ${cmd}" event=error rc="$rc" source="${src}:${line}"
}
log_trap_errors() { trap _log_on_err ERR; }
