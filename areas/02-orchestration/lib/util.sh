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
  for cmd in yq jq curl ssh scp git python3 sha256sum date; do
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

# ─── manifest_yq: multi-doc YAML 첫 doc 만 (v1.0 a1cb91f 함정 회피) ───
# Source: 02-RESEARCH § Code Examples 라인 673-682 + 04-04-SUMMARY § Deviations 항목 3
manifest_yq() {
  local field="$1" manifest="$2"
  yq eval-all "select(documentIndex == 0).${field}" "$manifest"
}
