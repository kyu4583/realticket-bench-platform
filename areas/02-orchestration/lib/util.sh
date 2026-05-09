#!/usr/bin/env bash
# areas/02-orchestration/lib/util.sh — parse_duration · manifest_yq + log/die/check_deps
# Source: areas/02-orchestration/README.md § run.sh 17 함수

# ─── Logger / die ───
log() {
  local level="${1:-INFO}"
  shift || true
  printf '[%s] [%s] %s\n' "$(date -u +%FT%TZ)" "$level" "$*" >&2
}

die() {
  log ERROR "$*"
  exit "${exit_code:-1}"
}

# ─── 의존 명령 검사 ───
check_deps() {
  local missing=0
  for cmd in yq jq curl ssh scp git python3 sha256sum date tee; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log ERROR "missing dep: $cmd"
      missing=$((missing + 1))
    fi
  done
  [[ $missing -eq 0 ]] || die "missing $missing required dependency(ies)"
}

# ─── parse_duration: 6h/10m/30s → 초 ───
# null/빈 입력 → 0, 비숫자 입력 → die (sleep null/산술 syntax error 차단)
parse_duration() {
  local s="${1:-}"
  case "$s" in
    "" | "null") echo 0 ;;
    *h) echo $(( ${s%h} * 3600 )) ;;
    *m) echo $(( ${s%m} * 60 )) ;;
    *s) echo $(( ${s%s} )) ;;
    *[!0-9]*) die "parse_duration: invalid duration '$s'" ;;  # 숫자 외 문자
    *) echo "$s" ;;  # 순수 숫자 → 초로 간주
  esac
}

# ─── timing helpers: Plan.json main_booking + Gatling static waits → wall-clock estimate ───
# ceil_div: positive integer ceiling division.
ceil_div() {
  local n="${1:-0}" d="${2:-1}"
  [[ "$d" -gt 0 ]] || die "ceil_div: denominator must be > 0 (got '$d')"
  echo $(( (n + d - 1) / d ))
}

# java_config_bool/int read simple Config.java constants. Unknown values fall back
# to the supplied default so timing estimation stays conservative but non-fatal.
java_config_bool() {
  local name="$1" file="$2" default="${3:-false}" line
  [[ -f "$file" ]] || { echo "$default"; return 0; }
  line=$(grep -E "^[[:space:]]*public static final boolean ${name}[[:space:]]*=" "$file" | head -1 || true)
  if printf '%s\n' "$line" | grep -qE '=[[:space:]]*true[[:space:]]*;'; then
    echo true
  elif printf '%s\n' "$line" | grep -qE '=[[:space:]]*false[[:space:]]*;'; then
    echo false
  elif printf '%s\n' "$line" | grep -qE '"true"'; then
    echo true
  elif printf '%s\n' "$line" | grep -qE '"false"'; then
    echo false
  else
    echo "$default"
  fi
}

java_config_int() {
  local name="$1" file="$2" default="${3:-0}" value
  [[ -f "$file" ]] || { echo "$default"; return 0; }
  value=$(sed -nE "s/.*public static final int ${name}[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p" "$file" | head -1)
  [[ -z "$value" ]] && value=$(sed -nE "s/.*public static final int ${name}.*prop\(\"[^\"]+\",[[:space:]]*\"([0-9]+)\"\).*/\1/p" "$file" | head -1)
  [[ -n "$value" ]] && echo "$value" || echo "$default"
}

# Static setup waits that are outside Plan.json's request schedule.
derive_gatling_static_wait_ms() {
  local config_file="$1" total_ms=0
  [[ -f "$config_file" ]] || { echo 0; return 0; }

  if [[ "$(java_config_bool ENABLE_STAGGERED_LOGIN "$config_file" false)" == "true" ]]; then
    total_ms=$(( total_ms + $(java_config_int STAGGERED_LOGIN_TIME_RANGE_MILLIS "$config_file" 0) ))
  fi
  if [[ "$(java_config_bool ENABLE_WAITING_BEFORE_SUBS "$config_file" false)" == "true" ]]; then
    total_ms=$(( total_ms + $(java_config_int WAITING_BEFORE_SUBS_MILLIS "$config_file" 0) ))
  fi
  if [[ "$(java_config_bool ENABLE_WAITING_AFTER_SUBS "$config_file" false)" == "true" ]]; then
    total_ms=$(( total_ms + $(java_config_int WAITING_AFTER_SUBS_MILLIS "$config_file" 0) ))
  fi

  echo "$total_ms"
}

derive_initial_iter_wall_s() {
  local main_booking_ms="$1" static_wait_ms="$2" runner_overhead_s="$3"
  local active_s
  active_s=$(ceil_div "$(( main_booking_ms + static_wait_ms ))" 1000)
  echo $(( active_s + runner_overhead_s ))
}

# ─── manifest_yq: multi-doc YAML 첫 doc 만 (v1.0 a1cb91f 함정 회피) ───
# Source: 02-RESEARCH § Code Examples 라인 673-682 + 04-04-SUMMARY § Deviations 항목 3
manifest_yq() {
  local field="$1" manifest="$2"
  yq eval-all "select(documentIndex == 0).${field}" "$manifest"
}
