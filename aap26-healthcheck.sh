#!/usr/bin/env bash
#
# aap26-healthcheck.sh
# Author: Magnus Glantz, sudo@redhat.com, 2026
#
# ---------------------------------------------------------------------------
# Full health check for a containerized Ansible Automation Platform 2.6 node.
#
# Containerized AAP 2.6 runs as ROOTLESS Podman under the install user, managed
# by systemd *user* units (quadlets). Run this script AS THAT USER (not root,
# unless your install genuinely runs rootful).
#
# Usage:
#   ./aap26-healthcheck.sh --nodetype <controller|gateway|hub|execution|all> --api-host https://your-aap.example.com --tokenfile ./tokenfile
#
# Options:
#   --nodetype TYPE     Role of this node (required). One of:
#                         controller  - Automation Controller
#                         gateway     - Platform Gateway (+ Envoy proxy)
#                         hub         - Automation Hub (Pulp)
#                         execution   - Execution node (Receptor only)
#                         all         - All-in-one / single-node deployment
#   --api-host HOST     Base host for API probes (default: https://localhost)
#   --token-file FILE   Read the bearer token from FILE (first line).
#   --log-lines N       Lines of container log to scan for errors (default: 200)
#   --verbose, -v       Show extra detail (full container list, log excerpts)
#   --no-color          Disable colored output
#   --help, -h          Show this help
#
# Exit codes: 0 = no failures, 1 = one or more FAIL checks.
# ---------------------------------------------------------------------------

set -uo pipefail
# NOTE: deliberately NOT using `set -e`. Health checks expect non-zero exits
# from probed commands; failures are handled explicitly per check.

# ----------------------------- configuration -------------------------------
NODETYPE=""
API_HOST="https://localhost"
LOG_LINES=200
VERBOSE=0
USE_COLOR=1
TOKEN=""
TOKEN_FILE=""
TOKEN_SOURCE=""

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# ----------------------------- arg parsing ---------------------------------
print_help() {
  cat <<'EOF'
aap26-healthcheck.sh - Health check for a containerized AAP 2.6 node.

Containerized AAP 2.6 runs as ROOTLESS Podman under the install user, managed
by systemd *user* units. Run this script AS THAT USER (not root, unless your
install genuinely runs rootful).

Usage:
  ./aap26-healthcheck.sh --nodetype <controller|gateway|hub|execution|all> [options]

Options:
  --nodetype TYPE     Role of this node (required):
                        controller | gateway | hub | eda | execution | all
  --api-host HOST     Base host for API probes (default: https://localhost)
  --token TOKEN       Bearer token for authenticated API calls. NOTE: visible
                        in the process list / shell history; prefer the methods
                        below for anything sensitive.
  --token-file FILE   Read the bearer token from FILE (first line).
  --log-lines N       Lines of container log to scan for errors (default: 200)
  --verbose, -v       Show extra detail (full container list, log excerpts)
  --no-color          Disable colored output
  --help, -h          Show this help

A token may also be supplied via the AAP_TOKEN environment variable.
Precedence: --token  >  --token-file  >  $AAP_TOKEN.

Exit codes: 0 = no failures, 1 = one or more FAIL checks.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nodetype)  NODETYPE="${2:-}"; shift 2 ;;
    --nodetype=*) NODETYPE="${1#*=}"; shift ;;
    --api-host)  API_HOST="${2:-}"; shift 2 ;;
    --api-host=*) API_HOST="${1#*=}"; shift ;;
    --token)     TOKEN="${2:-}"; TOKEN_SOURCE="cli"; shift 2 ;;
    --token=*)   TOKEN="${1#*=}"; TOKEN_SOURCE="cli"; shift ;;
    --token-file)   TOKEN_FILE="${2:-}"; shift 2 ;;
    --token-file=*) TOKEN_FILE="${1#*=}"; shift ;;
    --log-lines) LOG_LINES="${2:-}"; shift 2 ;;
    --log-lines=*) LOG_LINES="${1#*=}"; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    --no-color)  USE_COLOR=0; shift ;;
    -h|--help)   print_help; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; echo "Try --help" >&2; exit 2 ;;
  esac
done

NODETYPE="$(echo "${NODETYPE}" | tr '[:upper:]' '[:lower:]')"
case "${NODETYPE}" in
  controller|gateway|hub|eda|execution|all) ;;
  "") echo "ERROR: --nodetype is required." >&2; echo "Try --help" >&2; exit 2 ;;
  *)  echo "ERROR: invalid --nodetype '${NODETYPE}'." >&2; echo "Valid: controller, gateway, hub, eda, execution, all" >&2; exit 2 ;;
esac

# ----------------------------- token resolution ----------------------------
# Precedence: --token > --token-file > $AAP_TOKEN
if [[ -z "${TOKEN}" && -n "${TOKEN_FILE}" ]]; then
  if [[ -r "${TOKEN_FILE}" ]]; then
    TOKEN="$(sed -n '1p' "${TOKEN_FILE}" | tr -d '\r\n')"
    TOKEN_SOURCE="file"
  else
    echo "ERROR: --token-file '${TOKEN_FILE}' is not readable." >&2; exit 2
  fi
fi
if [[ -z "${TOKEN}" && -n "${AAP_TOKEN:-}" ]]; then
  TOKEN="${AAP_TOKEN}"
  TOKEN_SOURCE="env"
fi

# Build curl auth args once. Empty array expands to nothing on bash 4.4+.
AUTH_ARGS=()
if [[ -n "${TOKEN}" ]]; then
  AUTH_ARGS=(-H "Authorization: Bearer ${TOKEN}")
fi

# ----------------------------- expected secrets ----------------------------
# Podman secrets created by the containerized installer, grouped by component.
# Validated per node type below. 'database' secrets live on the node hosting
# the managed PostgreSQL; on a node using an external/remote DB they will be
# absent (and reported as FAIL) — move them out of the group for that topology.
SECRETS_DATABASE=(postgresql_admin_password)
SECRETS_GATEWAY=(gateway_secret_key gateway_db_password gateway_admin_password gateway_redis_url)
SECRETS_CONTROLLER=(controller_channels controller_resource_server controller_postgres controller_secret_key)
SECRETS_EDA=(eda_resource_server eda_secret_key eda_admin_password eda_db_password)
SECRETS_HUB=(hub_secret_key hub_collection_signing_passphrase hub_settings hub_database_fields hub_resource_server hub_container_signing_passphrase)

# ----------------------------- output helpers ------------------------------
if [[ "${USE_COLOR}" -eq 1 && -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BOLD=""; C_RST=""
fi

section() { printf '\n%s== %s ==%s\n' "${C_BOLD}${C_BLU}" "$1" "${C_RST}"; }
pass()    { printf '  %s[ PASS ]%s %s\n' "${C_GRN}" "${C_RST}" "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
warn()    { printf '  %s[ WARN ]%s %s\n' "${C_YEL}" "${C_RST}" "$1"; WARN_COUNT=$((WARN_COUNT+1)); }
fail()    { printf '  %s[ FAIL ]%s %s\n' "${C_RED}" "${C_RST}" "$1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
info()    { printf '  %s[ INFO ]%s %s\n' "${C_BLU}" "${C_RST}" "$1"; }
detail()  { [[ "${VERBOSE}" -eq 1 ]] && printf '         %s\n' "$1"; return 0; }

have() { command -v "$1" >/dev/null 2>&1; }

# Match a single running container name by extended-regex pattern.
find_container() {
  podman ps --format '{{.Names}}' 2>/dev/null | grep -E "$1" | head -n1
}

# Match all running container names by pattern.
find_containers() {
  podman ps --format '{{.Names}}' 2>/dev/null | grep -E "$1"
}

# Run a command inside a container; prints output, returns its rc.
exec_in() {
  local c="$1"; shift
  podman exec "${c}" "$@" 2>/dev/null
}

# HTTP probe: returns the status code. Any code (even 401/403) proves the
# service is listening and serving HTTP; empty means connection failed.
http_code() {
  curl -sk -o /dev/null -m 10 "${AUTH_ARGS[@]}" -w '%{http_code}' "$1" 2>/dev/null
}

# ----------------------------- preflight -----------------------------------
preflight() {
  section "Preflight"

  if ! have podman; then
    fail "podman not found in PATH — cannot inspect containerized AAP."
    summary; exit 1
  fi
  local pv; pv="$(podman version --format '{{.Client.Version}}' 2>/dev/null || echo '?')"
  pass "podman present (client ${pv})"

  # Rootless / runtime-dir context. systemd --user and the rootless podman
  # socket both depend on XDG_RUNTIME_DIR being set for the login session.
  if [[ "$(id -u)" -eq 0 ]]; then
    warn "Running as root. Containerized AAP is usually rootless under the install user — make sure that's intended."
  else
    pass "Running as non-root user '$(id -un)' (expected for rootless install)"
  fi

  if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    warn "XDG_RUNTIME_DIR is not set — 'systemctl --user' and rootless podman may misbehave. Use a real login session (e.g. 'su - <user>' or 'machinectl shell')."
  else
    detail "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}"
  fi

  if ! podman info >/dev/null 2>&1; then
    fail "'podman info' failed — Podman engine not reachable for this user."
  else
    local rootless; rootless="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo '?')"
    pass "Podman engine reachable (rootless=${rootless})"
  fi

  # API authentication mode (never print the token itself).
  if [[ -n "${TOKEN}" ]]; then
    info "API auth: bearer token supplied (source: ${TOKEN_SOURCE})"
    [[ "${TOKEN_SOURCE}" == "cli" ]] && warn "Token passed on the command line is visible in 'ps' / shell history — prefer --token-file or \$AAP_TOKEN."
  else
    info "API auth: none — authenticated endpoints will report as auth-required, not failures."
  fi
}

# ----------------------------- SELinux -------------------------------------
# Containerized AAP runs rootless Podman; SELinux confinement (container_t +
# correctly labeled volumes) is what keeps the containers isolated. Disabled
# SELinux is unsupported; recent denials are a common root cause of containers
# failing to read mounts/sockets.
check_selinux() {
  section "SELinux"

  if ! have getenforce; then
    fail "getenforce not found — SELinux userspace tooling missing. Containerized AAP requires SELinux enabled (Enforcing)."
    return
  fi

  # Runtime mode.
  local mode; mode="$(getenforce 2>/dev/null)"
  case "${mode}" in
    Enforcing)  pass "Runtime mode: Enforcing" ;;
    Permissive) warn "Runtime mode: Permissive (supported but not recommended — denials are logged, not blocked)" ;;
    Disabled)   fail "Runtime mode: Disabled — unsupported for AAP; container labeling/isolation is off" ;;
    *)          warn "Runtime mode: unknown (${mode:-none})" ;;
  esac

  # Persistent config vs runtime (will the mode survive a reboot?).
  if [[ -r /etc/selinux/config ]]; then
    local cfg; cfg="$(awk -F= '/^[[:space:]]*SELINUX=/{print $2}' /etc/selinux/config 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "${cfg}" ]]; then
      detail "Persistent setting: SELINUX=${cfg} (/etc/selinux/config)"
      if [[ "${mode}" == "Enforcing" && "${cfg}" != "enforcing" ]]; then
        warn "Runtime is Enforcing but config has SELINUX=${cfg} — mode will revert to '${cfg}' on reboot"
      elif [[ "${mode}" == "Disabled" && "${cfg}" == "enforcing" ]]; then
        warn "Config requests enforcing but runtime is Disabled — a relabel + reboot is needed to re-enable"
      fi
    fi
  fi

  # Loaded policy type (should be 'targeted').
  if have sestatus; then
    local pol
    pol="$(sestatus 2>/dev/null | awk -F: '/Loaded policy name/{gsub(/^[ \t]+/,"",$2);print $2}')"
    [[ -z "${pol}" ]] && pol="$(sestatus 2>/dev/null | awk -F: '/Policy from config file/{gsub(/^[ \t]+/,"",$2);print $2}')"
    if [[ "${pol}" == "targeted" ]]; then pass "Loaded policy: targeted"
    elif [[ -n "${pol}" ]]; then warn "Loaded policy: ${pol} (expected 'targeted')"
    fi
  fi

  # container-selinux policy module — required for correct rootless labeling.
  if have rpm; then
    if rpm -q container-selinux >/dev/null 2>&1; then
      pass "container-selinux installed ($(rpm -q --qf '%{VERSION}-%{RELEASE}' container-selinux 2>/dev/null))"
    else
      fail "container-selinux not installed — Podman cannot apply container_t / volume labels correctly"
    fi
  fi

  # Confinement actually applied: sample a running container's process label.
  if [[ "${mode}" != "Disabled" ]]; then
    local sample plabel
    sample="$(podman ps --format '{{.Names}}' 2>/dev/null | grep -viE 'receptor' | head -n1)"
    if [[ -n "${sample}" ]]; then
      plabel="$(podman inspect --format '{{.ProcessLabel}}' "${sample}" 2>/dev/null)"
      if echo "${plabel}" | grep -q 'container_t'; then
        pass "Containers confined (sample '${sample}': type $(echo "${plabel}" | cut -d: -f3))"
      elif echo "${plabel}" | grep -qiE 'spc_t|unconfined'; then
        warn "Container '${sample}' label '${plabel}' is privileged/unconfined — verify this is intended"
      elif [[ -z "${plabel}" ]]; then
        warn "Container '${sample}' has no SELinux process label — labeling may be disabled"
      else
        info "Container '${sample}' process label: ${plabel}"
      fi
    fi
  fi

  # Recent denials — the usual culprit behind 'permission denied' on mounts.
  scan_selinux_denials
}

# Best-effort recent-denial scan. Needs read access to the audit log or the
# journal; degrades to an INFO when the (often rootless) user lacks access.
scan_selinux_denials() {
  local denials="" src="" readable=0

  if have ausearch && { [[ -r /var/log/audit/audit.log ]] || [[ "$(id -u)" -eq 0 ]]; }; then
    readable=1; src="audit log"
    denials="$(ausearch -m AVC,USER_AVC,SELINUX_ERR -ts today 2>/dev/null | grep -iE 'denied' || true)"
  elif have journalctl && journalctl -n0 >/dev/null 2>&1; then
    readable=1; src="journal"
    denials="$(journalctl --since today 2>/dev/null | grep -iE 'avc:[[:space:]]*denied|SELinux is preventing' || true)"
  fi

  if [[ "${readable}" -eq 0 ]]; then
    info "Denial scan skipped — no read access to audit log/journal (run as root, or join the audit/systemd-journal group)."
    return
  fi

  if [[ -n "${denials}" ]]; then
    local count; count="$(echo "${denials}" | grep -c .)"
    warn "${count} recent SELinux denial(s) today (${src}) — investigate: ausearch -m AVC -ts today | audit2why"
    [[ "${VERBOSE}" -eq 1 ]] && echo "${denials}" | tail -n 5 | while read -r l; do detail "${l}"; done
  else
    pass "No SELinux denials recorded today (${src})"
  fi
}

# ----------------------------- common checks -------------------------------
common_checks() {
  section "System resources"

  # Memory
  if have free; then
    local mem; mem="$(free -m | awk '/^Mem:/{printf "%d", $7}')"  # available MB
    if [[ -n "${mem}" && "${mem}" -lt 1024 ]]; then
      fail "Low available memory: ${mem} MB free"
    else
      pass "Available memory: ${mem} MB"
    fi
  fi

  # Load average vs core count
  if [[ -r /proc/loadavg ]]; then
    local la cores; la="$(awk '{print $1}' /proc/loadavg)"
    cores="$(nproc 2>/dev/null || echo 1)"
    info "Load average (1m): ${la} over ${cores} core(s)"
  fi

  # Disk space on key paths. Podman graphroot is where images/containers live.
  local graphroot; graphroot="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null)"
  local paths=(/ /var "${HOME}")
  [[ -n "${graphroot}" ]] && paths+=("${graphroot}")
  local seen=""
  for p in "${paths[@]}"; do
    [[ -d "${p}" ]] || continue
    case " ${seen} " in *" ${p} "*) continue ;; esac
    seen="${seen} ${p}"
    local usep; usep="$(df -P "${p}" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
    [[ -z "${usep}" ]] && continue
    if   [[ "${usep}" -ge 90 ]]; then fail "Disk ${p} is ${usep}% full"
    elif [[ "${usep}" -ge 80 ]]; then warn "Disk ${p} is ${usep}% full"
    else pass "Disk ${p} at ${usep}%"
    fi
  done

  check_selinux

  section "Systemd user units (AAP quadlets)"
  if have systemctl; then
    local failed
    failed="$(systemctl --user --failed --no-legend 2>/dev/null | awk '{print $1}')"
    if [[ -n "${failed}" ]]; then
      fail "Failed systemd --user units detected:"
      while read -r u; do [[ -n "${u}" ]] && printf '           - %s\n' "${u}"; done <<< "${failed}"
    else
      pass "No failed systemd --user units"
    fi
    if [[ "${VERBOSE}" -eq 1 ]]; then
      detail "AAP-related units:"
      systemctl --user list-units --type=service --no-legend 2>/dev/null \
        | grep -iE 'automation|receptor|postgres|redis|pulp|gateway|eda' \
        | while read -r line; do detail "  ${line}"; done
    fi
  else
    info "systemctl not available; skipping unit check"
  fi

  section "Containers"
  local total running
  total="$(podman ps -a --format '{{.Names}}' 2>/dev/null | grep -c . || true)"
  running="$(podman ps    --format '{{.Names}}' 2>/dev/null | grep -c . || true)"
  if [[ "${total}" -eq 0 ]]; then
    fail "No containers found at all — is this node provisioned?"
  else
    info "${running}/${total} containers running"
  fi

  # Containers that exist but are not running.
  local stopped
  stopped="$(podman ps -a --filter 'status=exited' --filter 'status=created' \
              --format '{{.Names}} ({{.Status}})' 2>/dev/null)"
  if [[ -n "${stopped}" ]]; then
    while read -r line; do [[ -n "${line}" ]] && fail "Not running: ${line}"; done <<< "${stopped}"
  else
    [[ "${total}" -gt 0 ]] && pass "No exited/created (stopped) containers"
  fi

  # Unhealthy containers (those with a healthcheck reporting unhealthy).
  local unhealthy
  unhealthy="$(podman ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -i 'unhealthy' || true)"
  if [[ -n "${unhealthy}" ]]; then
    while read -r line; do [[ -n "${line}" ]] && fail "Unhealthy: ${line}"; done <<< "${unhealthy}"
  else
    pass "No containers reporting (unhealthy)"
  fi

  # Restart loops.
  while read -r name; do
    [[ -z "${name}" ]] && continue
    local rc; rc="$(podman inspect --format '{{.RestartCount}}' "${name}" 2>/dev/null || echo 0)"
    [[ -z "${rc}" ]] && rc=0
    if [[ "${rc}" -ge 5 ]]; then warn "${name} has restarted ${rc} times (possible crash loop)"; fi
  done <<< "$(podman ps --format '{{.Names}}' 2>/dev/null)"

  if [[ "${VERBOSE}" -eq 1 ]]; then
    detail "Full container list:"
    podman ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null \
      | while read -r line; do detail "  ${line}"; done
  fi

  section "Podman secrets"
  # Required secrets are validated per node type with 'podman secret exists'
  # (exit 0 = present). Secret-key mismatches/absences cause Fernet InvalidToken
  # errors on gateway preference init, so each expected secret must be present.
  if podman secret ls >/dev/null 2>&1; then
    local total_secrets
    total_secrets="$(podman secret ls --format '{{.Name}}' 2>/dev/null | grep -c . || true)"
    info "${total_secrets} podman secret(s) defined for this user"
    [[ "${VERBOSE}" -eq 1 ]] && podman secret ls --format '{{.Name}}' 2>/dev/null \
      | while read -r s; do detail "  ${s}"; done
    validate_secrets
  else
    fail "Cannot enumerate podman secrets for this user — secret validation skipped"
  fi

  scan_logs_common
}

# Validate the podman secrets expected for this node type. Uses
# 'podman secret exists NAME'; ONLY exit code 0 counts as present.
validate_secrets() {
  local -a expected=()
  case "${NODETYPE}" in
    gateway)    expected=("${SECRETS_DATABASE[@]}" "${SECRETS_GATEWAY[@]}") ;;
    controller) expected=("${SECRETS_DATABASE[@]}" "${SECRETS_CONTROLLER[@]}") ;;
    hub)        expected=("${SECRETS_DATABASE[@]}" "${SECRETS_HUB[@]}") ;;
    eda)        expected=("${SECRETS_DATABASE[@]}" "${SECRETS_EDA[@]}") ;;
    execution)
      info "Execution nodes carry no application secrets (Receptor uses TLS certs) — no podman secrets to validate."
      return ;;
    all)        expected=("${SECRETS_DATABASE[@]}" "${SECRETS_GATEWAY[@]}" \
                          "${SECRETS_CONTROLLER[@]}" "${SECRETS_EDA[@]}" "${SECRETS_HUB[@]}") ;;
  esac

  local s missing=0
  for s in "${expected[@]}"; do
    if podman secret exists "${s}" >/dev/null 2>&1; then
      pass "Secret present: ${s}"
    else
      fail "Secret MISSING: ${s} ('podman secret exists ${s}' returned non-zero)"
      missing=$((missing+1))
    fi
  done
  [[ "${missing}" -eq 0 && "${#expected[@]}" -gt 0 ]] \
    && info "All ${#expected[@]} expected secret(s) for nodetype '${NODETYPE}' are present"
}

# Scan logs of all AAP-ish containers for error signatures.
scan_logs_common() {
  section "Log error scan (last ${LOG_LINES} lines/container)"
  local pattern='error|critical|traceback|fatal|invalidtoken|connection refused|could not connect'
  local any=0
  while read -r c; do
    [[ -z "${c}" ]] && continue
    local hits
    hits="$(podman logs --tail "${LOG_LINES}" "${c}" 2>&1 | grep -icE "${pattern}" || true)"
    if [[ "${hits}" -gt 0 ]]; then
      any=1
      warn "${c}: ${hits} error-like line(s) in recent logs"
      if [[ "${VERBOSE}" -eq 1 ]]; then
        podman logs --tail "${LOG_LINES}" "${c}" 2>&1 | grep -iE "${pattern}" | tail -n 5 \
          | while read -r l; do detail "  ${l}"; done
      fi
    fi
  done <<< "$(find_containers 'automation|gateway|controller|pulp|hub|receptor|postgres|redis|eda')"
  [[ "${any}" -eq 0 ]] && pass "No error-like log lines found in recent output"
}

# ----------------------------- shared probes -------------------------------
check_redis() {
  local c; c="$(find_container 'redis')"
  if [[ -z "${c}" ]]; then
    warn "No Redis container found locally (may be remote/shared)"
    return
  fi
  pass "Redis container present (${c})"
}

check_postgres() {
  local c; c="$(find_container 'postgres')"
  if [[ -z "${c}" ]]; then
    info "No local PostgreSQL container — database is likely external/managed. Verify connectivity from app logs."
    return
  fi
  if exec_in "${c}" pg_isready >/dev/null 2>&1; then
    pass "PostgreSQL (${c}) accepting connections"
    if [[ "${VERBOSE}" -eq 1 ]]; then
      local conns
      conns="$(exec_in "${c}" psql -tAc 'SELECT count(*) FROM pg_stat_activity;' 2>/dev/null)"
      [[ -n "${conns}" ]] && detail "Active backends: ${conns}"
    fi
  else
    fail "PostgreSQL (${c}) not ready (pg_isready failed)"
  fi
}

check_receptor() {
  local c; c="$(find_container 'receptor')"
  if [[ -z "${c}" ]]; then
    fail "No receptor container found"
    return
  fi
  pass "Receptor container present (${c})"
}

# Treat any HTTP status as "service is up"; only no-response is a failure.
# When a token was supplied, a 401/403 means the token itself is the problem.
probe_api() {
  local label="$1" url="$2"
  local code; code="$(http_code "${url}")"
  if [[ -z "${code}" || "${code}" == "000" ]]; then
    fail "${label} unreachable (${url})"
  elif [[ "${code}" =~ ^(200|301|302)$ ]]; then
    pass "${label} responding (HTTP ${code})"
  elif [[ "${code}" =~ ^(401|403)$ ]]; then
    if [[ -n "${TOKEN}" ]]; then
      warn "${label} returned HTTP ${code} despite token — token may be invalid, expired, or lack scope (${url})"
    else
      pass "${label} responding (HTTP ${code}; auth required — pass --token to authenticate)"
    fi
  else
    warn "${label} returned HTTP ${code} (${url})"
  fi
}

# ----------------------------- port listeners ------------------------------
# Validates the local listening ports per Table 4 (Network ports and protocols).
# Only the DESTINATION side (a listener) is verifiable locally; outbound/source
# flows (e.g. this node -> external DB) need a reachability test with a target.
# Port 443 anchoring (":443$") deliberately does not match ":8443".
port_listening() {
  local p="$1"
  ss -tln 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]${p}\$"
}

# check_listen SEVERITY PORT...   (https=fail, http=warn — HTTP is often a
# redirect and may be disabled, HTTPS is required).
check_listen() {
  local sev="$1"; shift
  local p
  for p in "$@"; do
    if port_listening "${p}"; then
      pass "Listening on ${p}/tcp"
    elif [[ "${sev}" == "fail" ]]; then
      fail "Not listening on ${p}/tcp (expected for nodetype '${NODETYPE}')"
    else
      warn "Not listening on ${p}/tcp (expected for nodetype '${NODETYPE}'; may be disabled in config)"
    fi
  done
}

# Shared infra (Postgres/Redis): assert only when the container is local. Never
# hard-FAIL — an external/managed DB, a pod-internal bind, or non-clustered
# Redis are all legitimate and would otherwise produce false failures.
check_infra_port() {
  local cpat="$1" port="$2" label="$3"
  local c; c="$(find_container "${cpat}")"
  if [[ -z "${c}" ]]; then
    info "${label} (${port}/tcp): no local ${cpat} container — external/remote, not checked here"
    return
  fi
  if port_listening "${port}"; then
    pass "${label} listening on ${port}/tcp (${c})"
  else
    warn "${label} container present (${c}) but ${port}/tcp not host-listening (may bind pod-internally)"
  fi
}

check_ports() {
  section "Network listeners (Table 4)"

  if ! have ss; then
    warn "ss (iproute2) not available — cannot validate listening ports"
    return
  fi

  # Component NGINX ports (configurable via the *_nginx_http/https_port vars)
  # plus the gateway external HTTPS entry (443).
  case "${NODETYPE}" in
    gateway)    check_listen fail 443 8446 ;;
    controller) check_listen fail 8443;  check_listen warn 8080 ;;
    hub)        check_listen fail 8444;  check_listen warn 8081 ;;
    eda)        check_listen fail 8445;  check_listen warn 8082 ;;
    execution)  info "No listener ports validated for execution nodes." ;;
    all)        check_listen fail 443 8443 8444 8445 8446
                check_listen warn 8080 8081 8082 ;;
  esac

  # PostgreSQL (5432) — controller/gateway/hub/eda all connect to the DB.
  case "${NODETYPE}" in
    gateway|controller|hub|eda|all) check_infra_port postgres 5432 "PostgreSQL" ;;
  esac

  # Redis (6379) — gateway and EDA are the documented Redis clients; cluster
  # bus (16379) only on a clustered (multi-node HA) Redis.
  case "${NODETYPE}" in
    gateway|eda|all)
      check_infra_port redis 6379 "Redis"
      local rc; rc="$(find_container redis)"
      if [[ -n "${rc}" ]]; then
        if port_listening 16379; then pass "Redis cluster bus listening on 16379/tcp (clustered)"
        else info "Redis cluster bus 16379/tcp not listening — single-node (non-clustered) Redis"
        fi
      fi
      ;;
  esac
}

# ----------------------------- node: gateway -------------------------------
check_gateway() {
  section "Gateway role checks"

  local gw; gw="$(find_container 'gateway' | grep -viE 'proxy|envoy' | head -n1)"
  [[ -z "${gw}" ]] && gw="$(find_container 'gateway')"
  if [[ -n "${gw}" ]]; then pass "Gateway container present (${gw})"
  else fail "No gateway container found"
  fi

  # Envoy proxy fronts the gateway; confirm its container is running.
  local envoy; envoy="$(find_containers 'gateway|envoy|proxy' | grep -iE 'proxy|envoy' | head -n1)"
  if [[ -n "${envoy}" ]]; then
    pass "Gateway proxy/Envoy container present (${envoy})"
  else
    warn "No Envoy/proxy container matched"
  fi

  probe_api "Gateway API" "${API_HOST}/api/gateway/v1/"
  probe_api "Platform login page" "${API_HOST}/"

  # Fernet / secret-key mismatch surfaces as InvalidToken in gateway logs
  # during initialize_preferences(); call it out specifically.
  if [[ -n "${gw}" ]]; then
    local ft
    ft="$(podman logs --tail "${LOG_LINES}" "${gw}" 2>&1 | grep -ciE 'invalidtoken|fernet|decrypt' || true)"
    if [[ "${ft}" -gt 0 ]]; then
      fail "Gateway log shows ${ft} Fernet/InvalidToken line(s) — likely secret-key mismatch across nodes. Verify *_secret_key vars and podman secrets match."
    else
      pass "No Fernet/InvalidToken signatures in gateway log"
    fi
  fi

  check_redis
  check_postgres
}

# --------------------------- node: controller ------------------------------
check_controller() {
  section "Controller role checks"

  local web task
  web="$(find_containers 'controller' | grep -iE 'web' | head -n1)"
  task="$(find_containers 'controller' | grep -iE 'task' | head -n1)"
  [[ -n "${web}"  ]] && pass "Controller web container present (${web})"   || warn "No controller web container matched (naming may differ)"
  [[ -n "${task}" ]] && pass "Controller task container present (${task})" || warn "No controller task container matched (naming may differ)"
  if [[ -z "${web}" && -z "${task}" ]]; then
    local anyc; anyc="$(find_container 'controller|awx')"
    [[ -n "${anyc}" ]] && info "Found controller-ish container: ${anyc}" || fail "No controller containers found"
  fi

  # /ping/ is unauthenticated and reports HA instances + capacity.
  probe_api "Controller API ping" "${API_HOST}/api/controller/v2/ping/"
  local ping_json
  ping_json="$(curl -sk -m 10 "${AUTH_ARGS[@]}" "${API_HOST}/api/controller/v2/ping/" 2>/dev/null)"
  if [[ -n "${ping_json}" ]]; then
    if echo "${ping_json}" | grep -qi '"ha"'; then
      detail "Ping payload received"
      [[ "${VERBOSE}" -eq 1 ]] && echo "${ping_json}" | sed 's/^/         /'
    fi
  fi

  # Dispatcher / task processing sanity from task container logs.
  if [[ -n "${task}" ]]; then
    if podman logs --tail "${LOG_LINES}" "${task}" 2>&1 | grep -qiE 'dispatcher|scheduler|running'; then
      pass "Controller task container shows dispatcher/scheduler activity"
    else
      warn "No recent dispatcher/scheduler activity in task logs (may just be idle)"
    fi
  fi

  # Metrics endpoint requires auth (expect 401/403 when unauthenticated).
  probe_api "Controller metrics endpoint" "${API_HOST}/api/controller/v2/metrics/"

  check_redis
  check_postgres
  check_receptor
}

# ------------------------------ node: hub ----------------------------------
check_hub() {
  section "Automation Hub role checks"

  local pulp_api pulp_content pulp_worker
  pulp_api="$(find_containers 'hub|pulp' | grep -iE 'api' | head -n1)"
  pulp_content="$(find_containers 'hub|pulp' | grep -iE 'content' | head -n1)"
  pulp_worker="$(find_containers 'hub|pulp' | grep -iE 'worker' | head -n1)"
  [[ -n "${pulp_api}"     ]] && pass "Hub/Pulp API container present (${pulp_api})"         || warn "No Pulp API container matched"
  [[ -n "${pulp_content}" ]] && pass "Hub/Pulp content container present (${pulp_content})" || warn "No Pulp content container matched"
  [[ -n "${pulp_worker}"  ]] && pass "Hub/Pulp worker container present (${pulp_worker})"   || warn "No Pulp worker container matched"
  if [[ -z "${pulp_api}${pulp_content}${pulp_worker}" ]]; then
    local anyh; anyh="$(find_container 'hub|pulp|galaxy')"
    [[ -n "${anyh}" ]] && info "Found hub-ish container: ${anyh}" || fail "No Automation Hub containers found"
  fi

  # The Pulp status endpoint is unauthenticated and reports DB/redis/worker health.
  probe_api "Hub status API" "${API_HOST}/api/galaxy/pulp/api/v3/status/"
  local status_json
  status_json="$(curl -sk -m 10 "${AUTH_ARGS[@]}" "${API_HOST}/api/galaxy/pulp/api/v3/status/" 2>/dev/null)"
  if [[ -n "${status_json}" ]] && have python3; then
    # Pull database connected + online worker count without assuming jq exists.
    local dbconn workers
    dbconn="$(echo "${status_json}" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(d.get("database_connection",{}).get("connected"))
except Exception: print("")' 2>/dev/null)"
    workers="$(echo "${status_json}" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(len(d.get("online_workers",[])))
except Exception: print("")' 2>/dev/null)"
    [[ "${dbconn}" == "True" ]] && pass "Pulp reports database connected" || { [[ -n "${dbconn}" ]] && fail "Pulp reports database NOT connected"; }
    if [[ -n "${workers}" ]]; then
      if [[ "${workers}" -gt 0 ]]; then pass "Pulp reports ${workers} online worker(s)"
      else fail "Pulp reports 0 online workers (content tasks will hang)"
      fi
    fi
  fi

  # Content/artifact storage space.
  local graphroot; graphroot="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null)"
  detail "Confirm artifact storage volume has headroom (often a dedicated mount)."

  check_redis
  check_postgres   # hub DB is typically named 'pulp'
}

# --------------------------- node: execution -------------------------------
check_execution() {
  section "Execution node role checks"

  check_receptor

  # Execution environment images present.
  local ee_count
  ee_count="$(podman images --format '{{.Repository}}' 2>/dev/null | grep -ciE 'ee-|execution-environment|automation-ee' || true)"
  if [[ "${ee_count}" -gt 0 ]]; then
    pass "${ee_count} execution environment image(s) present"
    [[ "${VERBOSE}" -eq 1 ]] && podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
      | grep -iE 'ee-|execution-environment|automation-ee' | while read -r i; do detail "  ${i}"; done
  else
    warn "No execution environment images detected — jobs may pull on first run, or images aren't pre-seeded"
  fi

  # An execution node should NOT be running web/db/gateway services.
  local strays
  strays="$(find_containers 'gateway|controller-web|controller-task|pulp|hub' || true)"
  if [[ -n "${strays}" ]]; then
    warn "Found service containers that don't belong on a pure execution node:"
    echo "${strays}" | while read -r s; do [[ -n "${s}" ]] && printf '           - %s\n' "${s}"; done
  else
    pass "No misplaced control-plane containers on this execution node"
  fi

  info "Execution nodes reach the control plane over the receptor mesh — confirm this node appears in the controller's instance list."
}

# ------------------------------ node: eda ----------------------------------
check_eda() {
  section "EDA (Event-Driven Ansible) role checks"

  local api worker
  api="$(find_containers 'eda' | grep -iE 'api|server|web' | head -n1)"
  worker="$(find_containers 'eda' | grep -iE 'worker|activation|scheduler|daphne' | head -n1)"
  [[ -n "${api}"    ]] && pass "EDA API/server container present (${api})"   || warn "No EDA API/server container matched"
  [[ -n "${worker}" ]] && pass "EDA worker/scheduler container present (${worker})" || warn "No EDA worker container matched"
  if [[ -z "${api}${worker}" ]]; then
    local anye; anye="$(find_container 'eda')"
    [[ -n "${anye}" ]] && info "Found EDA-ish container: ${anye}" || fail "No EDA containers found"
  fi

  probe_api "EDA API" "${API_HOST}/api/eda/v1/"

  check_redis
  check_postgres
}

# ------------------------------- summary -----------------------------------
summary() {
  section "Summary"
  printf '  %sPASS: %d%s   %sWARN: %d%s   %sFAIL: %d%s\n' \
    "${C_GRN}" "${PASS_COUNT}" "${C_RST}" \
    "${C_YEL}" "${WARN_COUNT}" "${C_RST}" \
    "${C_RED}" "${FAIL_COUNT}" "${C_RST}"
  if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    printf '\n  %sNode type %s: health check found failures.%s\n' "${C_RED}${C_BOLD}" "${NODETYPE}" "${C_RST}"
  elif [[ "${WARN_COUNT}" -gt 0 ]]; then
    printf '\n  %sNode type %s: healthy with warnings.%s\n' "${C_YEL}${C_BOLD}" "${NODETYPE}" "${C_RST}"
  else
    printf '\n  %sNode type %s: all checks passed.%s\n' "${C_GRN}${C_BOLD}" "${NODETYPE}" "${C_RST}"
  fi
}

# ------------------------------- main --------------------------------------
printf '%sAAP 2.6 Containerized Health Check%s\n' "${C_BOLD}" "${C_RST}"
printf 'Node type: %s   Host: %s   %s\n' "${NODETYPE}" "$(hostname -f 2>/dev/null || hostname)" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

preflight
common_checks
check_ports

case "${NODETYPE}" in
  gateway)    check_gateway ;;
  controller) check_controller ;;
  hub)        check_hub ;;
  eda)        check_eda ;;
  execution)  check_execution ;;
  all)        check_gateway; check_controller; check_eda; check_hub; check_execution ;;
esac

summary
[[ "${FAIL_COUNT}" -gt 0 ]] && exit 1 || exit 0
