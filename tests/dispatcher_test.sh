#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$ROOT_DIR/install.sh"

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

make_fake_release() {
  local root="$1"
  local os="$2"
  local arch="$3"
  local release_dir="$root/release"
  mkdir -p "$release_dir/bin"

  cat >"$release_dir/bin/loki-installer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${TEST_V2_LOG:?}"
EOF
  chmod +x "$release_dir/bin/loki-installer"

  tar -czf "$release_dir/loki-installer-$os-$arch.tar.gz" -C "$release_dir/bin" loki-installer
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$release_dir/loki-installer-$os-$arch.tar.gz" | awk '{print $1}' \
      >"$release_dir/loki-installer-$os-$arch.tar.gz.sha256"
  else
    shasum -a 256 "$release_dir/loki-installer-$os-$arch.tar.gz" | awk '{print $1}' \
      >"$release_dir/loki-installer-$os-$arch.tar.gz.sha256"
  fi
  printf '%s\n' "$release_dir"
}

assert_contains() {
  local needle="$1"
  local file="$2"
  grep -Fq -- "$needle" "$file" || {
    echo "expected '$needle' in $file" >&2
    exit 1
  }
}

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/dispatcher-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

os="$(normalize_os)"
arch="$(normalize_arch)"
release_dir="$(make_fake_release "$tmp_root" "$os" "$arch")"

cat >"$tmp_root/install-v1.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${TEST_V1_LOG:?}"
EOF
chmod +x "$tmp_root/install-v1.sh"

export TEST_V1_LOG="$tmp_root/v1.log"
export TEST_V2_LOG="$tmp_root/v2.log"
export LOKI_INSTALLER_V1_SCRIPT="$tmp_root/install-v1.sh"
export LOKI_INSTALLER_V2_BASE_URL="file://$release_dir"
export LOKI_INSTALLER_DEFAULT_ENGINE="v2"
export LOKI_INSTALLER_V2_VERSION="test"

rm -f "$TEST_V1_LOG" "$TEST_V2_LOG"
bash "$INSTALL_SH" --engine v1 --pack openclaw --non-interactive
assert_contains "--engine v1 --pack openclaw --non-interactive" "$TEST_V1_LOG"

rm -f "$TEST_V1_LOG" "$TEST_V2_LOG"
bash "$INSTALL_SH" --engine v2 --pack openclaw --method tf --non-interactive --json
assert_contains "install --pack openclaw --method terraform --non-interactive --json" "$TEST_V2_LOG"

printf '%s\n' "deadbeef" >"$release_dir/loki-installer-$os-$arch.tar.gz.sha256"
rm -f "$TEST_V1_LOG" "$TEST_V2_LOG"
bash "$INSTALL_SH" --pack openclaw --non-interactive
assert_contains "--pack openclaw --non-interactive" "$TEST_V1_LOG"

rm -f "$TEST_V1_LOG" "$TEST_V2_LOG"
if bash "$INSTALL_SH" --engine v2 --pack openclaw --non-interactive >"$tmp_root/explicit-v2.out" 2>"$tmp_root/explicit-v2.err"; then
  echo "expected explicit v2 checksum failure to exit non-zero" >&2
  exit 1
fi
assert_contains "V2 bootstrap failed: checksum_mismatch" "$tmp_root/explicit-v2.err"

echo "dispatcher tests passed"
