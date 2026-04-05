#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  echo "This script requires bash. Run with: bash $0" >&2
  exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_LOG="${TMPDIR:-/tmp}/loki-installer-bootstrap.log"
V1_SCRIPT="${LOKI_INSTALLER_V1_SCRIPT:-$SCRIPT_DIR/scripts/install-v1.sh}"
V2_REPO="${LOKI_INSTALLER_V2_REPO:-inceptionstack/loki-agent}"
V2_VERSION="${LOKI_INSTALLER_V2_VERSION:-latest}"
V2_BASE_URL="${LOKI_INSTALLER_V2_BASE_URL:-}"
DEFAULT_ENGINE="${LOKI_INSTALLER_DEFAULT_ENGINE:-v2}"

mkdir -p "$(dirname "$BOOTSTRAP_LOG")"

log_bootstrap() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$BOOTSTRAP_LOG"
}

fail() {
  echo "$*" >&2
  exit 1
}

normalize_os() {
  case "$(uname -s)" in
    Linux) echo "linux" ;;
    Darwin) echo "darwin" ;;
    *) echo "unsupported" ;;
  esac
}

normalize_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) echo "unsupported" ;;
  esac
}

canonical_method() {
  case "$1" in
    tf|terraform) echo "terraform" ;;
    cfn) echo "cfn" ;;
    *) echo "$1" ;;
  esac
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
    return
  fi
  fail "No SHA256 tool found — install sha256sum or shasum"
}

headless_complete() {
  [[ -n "${resume_session_id:-}" ]] && return 0
  [[ "${mode:-interactive}" == "non_interactive" && -n "${pack:-}" ]] && return 0
  return 1
}

exec_v1() {
  log_bootstrap "engine=v1 reason=${1:-selected}"
  exec bash "$V1_SCRIPT" "${RAW_ARGS[@]}"
}

fallback_or_fail() {
  local reason="$1"
  log_bootstrap "fallback reason=$reason explicit_v2=$EXPLICIT_V2 chosen=v1"
  if [[ "$EXPLICIT_V2" == "1" ]]; then
    fail "V2 bootstrap failed: $reason"
  fi
  exec_v1 "$reason"
}

resolve_base_url() {
  if [[ -n "$V2_BASE_URL" ]]; then
    echo "$V2_BASE_URL"
    return
  fi
  if [[ "$V2_VERSION" == "latest" ]]; then
    echo "https://github.com/$V2_REPO/releases/latest/download"
  else
    echo "https://github.com/$V2_REPO/releases/download/$V2_VERSION"
  fi
}

download_file() {
  local url="$1"
  local destination="$2"
  local timeout_seconds="$3"
  curl --fail --location --silent --show-error --max-time "$timeout_seconds" \
    --output "$destination" "$url"
}

download_and_verify_v2() {
  local os="$1"
  local arch="$2"
  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/loki-installer-v2.XXXXXX")"
  local base_url
  base_url="$(resolve_base_url)"
  local archive_name="loki-installer-${os}-${arch}.tar.gz"
  local archive_path="$temp_dir/$archive_name"
  local checksum_path="$archive_path.sha256"

  if ! download_file "$base_url/$archive_name" "$archive_path" 5; then
    rm -rf "$temp_dir"
    return 1
  fi

  if ! download_file "$base_url/$archive_name.sha256" "$checksum_path" 5; then
    rm -rf "$temp_dir"
    return 2
  fi

  local expected actual
  expected="$(awk '{print $1}' "$checksum_path")"
  actual="$(sha256_file "$archive_path")"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    rm -rf "$temp_dir"
    return 3
  fi

  tar -xzf "$archive_path" -C "$temp_dir"
  V2_BINARY_PATH="$(find "$temp_dir" -type f -name 'loki-installer' | head -n 1)"
  if [[ -z "${V2_BINARY_PATH:-}" || ! -f "$V2_BINARY_PATH" ]]; then
    rm -rf "$temp_dir"
    return 4
  fi
  chmod +x "$V2_BINARY_PATH"
  return 0
}

RAW_ARGS=("$@")
PASS_THROUGH_ARGS=()
UNKNOWN_FLAGS=()
EXPLICIT_V2=0
explicit_engine=""
pack=""
profile=""
method=""
region=""
stack_name=""
resume_session_id=""
mode=""
auto_yes=0
json_output=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)
      [[ $# -ge 2 ]] || fail "--engine requires v1 or v2"
      explicit_engine="$2"
      [[ "$2" == "v2" ]] && EXPLICIT_V2=1
      PASS_THROUGH_ARGS+=("$1" "$2")
      shift 2
      ;;
    --legacy)
      explicit_engine="v1"
      PASS_THROUGH_ARGS+=("$1")
      shift
      ;;
    --experience)
      [[ $# -ge 2 ]] || fail "--experience requires v1 or v2"
      explicit_engine="$2"
      [[ "$2" == "v2" ]] && EXPLICIT_V2=1
      PASS_THROUGH_ARGS+=("$1" "$2")
      shift 2
      ;;
    --non-interactive)
      mode="non_interactive"
      auto_yes=1
      PASS_THROUGH_ARGS+=("$1")
      shift
      ;;
    --yes|-y)
      auto_yes=1
      PASS_THROUGH_ARGS+=("$1")
      shift
      ;;
    --pack)
      [[ $# -ge 2 ]] || fail "--pack requires a value"
      pack="$2"
      PASS_THROUGH_ARGS+=("$1" "$2")
      shift 2
      ;;
    --profile)
      [[ $# -ge 2 ]] || fail "--profile requires a value"
      profile="$2"
      PASS_THROUGH_ARGS+=("$1" "$2")
      shift 2
      ;;
    --method)
      [[ $# -ge 2 ]] || fail "--method requires a value"
      method="$(canonical_method "$2")"
      PASS_THROUGH_ARGS+=("$1" "$2")
      shift 2
      ;;
    --region)
      [[ $# -ge 2 ]] || fail "--region requires a value"
      region="$2"
      PASS_THROUGH_ARGS+=("$1" "$2")
      shift 2
      ;;
    --stack-name)
      [[ $# -ge 2 ]] || fail "--stack-name requires a value"
      stack_name="$2"
      PASS_THROUGH_ARGS+=("$1" "$2")
      shift 2
      ;;
    --json)
      json_output=1
      PASS_THROUGH_ARGS+=("$1")
      shift
      ;;
    --resume)
      [[ $# -ge 2 ]] || fail "--resume requires a session id"
      resume_session_id="$2"
      PASS_THROUGH_ARGS+=("$1" "$2")
      shift 2
      ;;
    --*)
      UNKNOWN_FLAGS+=("$1")
      PASS_THROUGH_ARGS+=("$1")
      if [[ $# -ge 2 && "$2" != --* ]]; then
        PASS_THROUGH_ARGS+=("$2")
        shift 2
      else
        shift
      fi
      ;;
    *)
      PASS_THROUGH_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ -z "$mode" ]]; then
  if [[ -t 0 && -t 1 && $auto_yes -eq 0 ]]; then
    mode="interactive"
  else
    mode="non_interactive"
  fi
fi

requested_engine="$DEFAULT_ENGINE"
if [[ -n "$explicit_engine" ]]; then
  requested_engine="$explicit_engine"
elif [[ -n "${LOKI_INSTALLER_ENGINE:-}" ]]; then
  requested_engine="$LOKI_INSTALLER_ENGINE"
fi

if [[ "${LOKI_INSTALLER_FORCE_V1:-0}" == "1" ]]; then
  if [[ ! ("$requested_engine" == "v2" && "$EXPLICIT_V2" == "1" && "${LOKI_INSTALLER_ALLOW_FORCED_V2:-0}" == "1") ]]; then
    exec_v1 "force_v1"
  fi
fi

if [[ "$requested_engine" == "v1" ]]; then
  exec_v1 "explicit_v1"
fi

detected_os="$(normalize_os)"
detected_arch="$(normalize_arch)"
has_tty=0
[[ -t 0 && -t 1 ]] && has_tty=1

log_bootstrap "requested_engine=$requested_engine os=$detected_os arch=$detected_arch has_tty=$has_tty mode=$mode"

[[ "$detected_os" != "unsupported" ]] || fallback_or_fail "unsupported_os"
[[ "$detected_arch" != "unsupported" ]] || fallback_or_fail "unsupported_arch"

if [[ "$mode" == "interactive" && "$has_tty" -ne 1 ]]; then
  headless_complete || fallback_or_fail "no_tty_for_interactive_v2"
fi

if [[ ${#UNKNOWN_FLAGS[@]} -gt 0 ]]; then
  fallback_or_fail "unsupported_v2_flags:${UNKNOWN_FLAGS[*]}"
fi

if ! download_and_verify_v2 "$detected_os" "$detected_arch"; then
  case "$?" in
    1) fallback_or_fail "binary_download_timeout_or_failure" ;;
    2) fallback_or_fail "checksum_fetch_failed" ;;
    3) fallback_or_fail "checksum_mismatch" ;;
    *) fallback_or_fail "binary_extract_failed" ;;
  esac
fi

V2_ARGS=("install")
[[ -n "$pack" ]] && V2_ARGS+=("--pack" "$pack")
[[ -n "$profile" ]] && V2_ARGS+=("--profile" "$profile")
[[ -n "$method" ]] && V2_ARGS+=("--method" "$method")
[[ -n "$region" ]] && V2_ARGS+=("--region" "$region")
[[ -n "$stack_name" ]] && V2_ARGS+=("--stack-name" "$stack_name")
[[ -n "$resume_session_id" ]] && V2_ARGS+=("--resume" "$resume_session_id")
[[ "$mode" == "non_interactive" ]] && V2_ARGS+=("--non-interactive")
[[ $auto_yes -eq 1 && "$mode" != "non_interactive" ]] && V2_ARGS+=("--yes")
[[ $json_output -eq 1 ]] && V2_ARGS+=("--json")

log_bootstrap "engine=v2 binary=$V2_BINARY_PATH args=${V2_ARGS[*]}"
exec "$V2_BINARY_PATH" "${V2_ARGS[@]}"
