#!/usr/bin/env bash
# packs/ironclaw/install.sh — Install IronClaw and configure it to use bedrockify
#
# Usage:
#   ./install.sh [--region us-east-1] [--model us.anthropic.claude-sonnet-4-6-v1] [--bedrockify-port 8090]
#
# Assumes:
#   - bedrockify is already installed and running (see packs/bedrockify/)
#   - curl available
#   - IAM role with bedrock:InvokeModel permissions (handled by bedrockify)
#
# IronClaw is a single static Rust binary — no Rust/Cargo needed at runtime.
# We download the pre-built musl binary from GitHub releases.
#
# This script also installs:
#   - PostgreSQL 15 + pgvector (IronClaw requires PG with vector extension)
#   - D-Bus daemon (IronClaw's secret-service crate needs D-Bus on Linux;
#     without it, `ironclaw onboard` segfaults on headless EC2)
#
# NEAR AI OAuth is bypassed entirely — we write .env with
# LLM_BACKEND=openai_compatible, pointing at bedrockify.
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_MODEL="$(pack_config_get model "us.anthropic.claude-sonnet-4-6-v1")"
PACK_ARG_BEDROCKIFY_PORT="$(pack_config_get bedrockify_port "8090")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install IronClaw and configure it to use bedrockify.

Options:
  --region           AWS region for Bedrock          (default: us-east-1)
  --model            Model ID for LLM_MODEL           (default: us.anthropic.claude-sonnet-4-6-v1)
  --bedrockify-port  Port where bedrockify listens   (default: 8090)
  --help             Show this help message

Installs: IronClaw binary, PostgreSQL 15 + pgvector, D-Bus.
NEAR AI OAuth is bypassed; bedrockify handles all LLM access.

Examples:
  ./install.sh --region us-east-1
  ./install.sh --model us.anthropic.claude-sonnet-4-6-v1 --bedrockify-port 8090
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)          usage; exit 0 ;;
    --region)           PACK_ARG_REGION="$2";           shift 2 ;;
    --model)            PACK_ARG_MODEL="$2";             shift 2 ;;
    --bedrockify-port)  PACK_ARG_BEDROCKIFY_PORT="$2";  shift 2 ;;
    *) [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
  esac
done

REGION="${PACK_ARG_REGION}"
MODEL="${PACK_ARG_MODEL}"
BEDROCKIFY_PORT="${PACK_ARG_BEDROCKIFY_PORT}"

IC_DB_NAME="ironclaw"
IC_DB_USER="ec2-user"

pack_banner "ironclaw"
log "region=${REGION} model=${MODEL} bedrockify-port=${BEDROCKIFY_PORT}"

# ── Prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
require_cmd curl tar

check_bedrockify_health "${BEDROCKIFY_PORT}"

# ── D-Bus (prevents segfault in IronClaw's secret-service crate) ──────────────
step "D-Bus (secret-service dependency)"

# IronClaw links secret-service + zbus on Linux for keychain access.
# Without a D-Bus session bus, `ironclaw onboard` segfaults.
# We install dbus-daemon and start a session bus so the crate initializes safely.
if command -v dbus-daemon &>/dev/null; then
  ok "dbus-daemon already installed"
else
  log "Installing dbus-daemon..."
  sudo dnf install -y dbus dbus-daemon >/dev/null 2>&1
  ok "dbus-daemon installed"
fi

# Ensure system D-Bus is running (needed by secret-service)
if ! pgrep -x dbus-daemon &>/dev/null; then
  log "Starting D-Bus system bus..."
  sudo systemctl start dbus 2>/dev/null || sudo dbus-daemon --system --fork 2>/dev/null || true
fi

# Ensure session bus env var is available for ec2-user
# This prevents segfaults even if the user runs `ironclaw onboard` manually
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
  # Launch a session bus for this user if not already running
  if command -v dbus-launch &>/dev/null; then
    eval "$(dbus-launch --sh-syntax 2>/dev/null)" || true
  fi
fi

# Persist DBUS_SESSION_BUS_ADDRESS in .bashrc so future SSM sessions have it
if ! grep -q 'DBUS_SESSION_BUS_ADDRESS' "${HOME}/.bashrc" 2>/dev/null; then
  cat >> "${HOME}/.bashrc" <<'DBUS_BLOCK'

# D-Bus session bus for IronClaw secret-service (prevents segfault on headless)
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  if command -v dbus-launch &>/dev/null; then
    eval "$(dbus-launch --sh-syntax 2>/dev/null)" || true
  fi
fi
DBUS_BLOCK
  ok "D-Bus session bus auto-start added to .bashrc"
fi
ok "D-Bus ready"

# ── PostgreSQL 15 + pgvector ──────────────────────────────────────────────────
step "PostgreSQL 15"

# IronClaw requires PostgreSQL 15+ with the pgvector extension for semantic search.
# On AL2023, we install from the Amazon Linux repo; pgvector must be compiled from source.

if command -v psql &>/dev/null && psql --version 2>/dev/null | grep -q "15\.\|16\.\|17\."; then
  ok "PostgreSQL client already installed: $(psql --version)"
else
  log "Installing PostgreSQL 15..."
  sudo dnf install -y postgresql15 postgresql15-server postgresql15-contrib \
    postgresql15-server-devel >/dev/null 2>&1
  ok "PostgreSQL 15 installed"
fi

# Initialize database cluster if not done yet
PG_DATA="/var/lib/pgsql/data"
if [[ ! -f "${PG_DATA}/PG_VERSION" ]]; then
  log "Initializing PostgreSQL database cluster..."
  sudo postgresql-setup --initdb 2>/dev/null \
    || sudo -u postgres /usr/bin/initdb -D "${PG_DATA}" 2>/dev/null \
    || sudo /usr/bin/postgresql-setup initdb 2>/dev/null
  ok "PostgreSQL cluster initialized"
else
  ok "PostgreSQL cluster already initialized"
fi

# Configure pg_hba.conf for local peer authentication (ec2-user can connect)
PG_HBA="${PG_DATA}/pg_hba.conf"
if ! sudo grep -q "^local.*${IC_DB_NAME}.*${IC_DB_USER}" "${PG_HBA}" 2>/dev/null; then
  log "Configuring pg_hba.conf for local peer + TCP trust auth..."
  # Add before the first 'local' line: allow ec2-user to connect to ironclaw db
  sudo sed -i "/^local/i local   ${IC_DB_NAME}   ${IC_DB_USER}                              peer" "${PG_HBA}" 2>/dev/null \
    || echo "local   ${IC_DB_NAME}   ${IC_DB_USER}                              peer" | sudo tee -a "${PG_HBA}" >/dev/null
  # IronClaw connects via TCP (DATABASE_URL=postgresql://...@localhost) — need trust for 127.0.0.1
  if ! sudo grep -q "^host.*${IC_DB_NAME}.*${IC_DB_USER}.*trust" "${PG_HBA}" 2>/dev/null; then
    sudo sed -i "/^host.*all.*all.*127.0.0.1/i host    ${IC_DB_NAME}   ${IC_DB_USER}   127.0.0.1/32                    trust" "${PG_HBA}" 2>/dev/null \
      || echo "host    ${IC_DB_NAME}   ${IC_DB_USER}   127.0.0.1/32                    trust" | sudo tee -a "${PG_HBA}" >/dev/null
  fi
fi

# Start PostgreSQL
if sudo systemctl is-active --quiet postgresql 2>/dev/null; then
  ok "PostgreSQL already running"
  # Reload config in case we changed pg_hba.conf
  sudo systemctl reload postgresql 2>/dev/null || true
else
  log "Starting PostgreSQL..."
  sudo systemctl enable postgresql >/dev/null 2>&1
  sudo systemctl start postgresql
  ok "PostgreSQL started and enabled"
fi

# Create database user (if not exists) and database
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${IC_DB_USER}'" 2>/dev/null | grep -q 1; then
  ok "PostgreSQL role '${IC_DB_USER}' exists"
else
  log "Creating PostgreSQL role '${IC_DB_USER}'..."
  sudo -u postgres createuser "${IC_DB_USER}" 2>/dev/null || true
  ok "PostgreSQL role '${IC_DB_USER}' created"
fi

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${IC_DB_NAME}'" 2>/dev/null | grep -q 1; then
  ok "Database '${IC_DB_NAME}' exists"
else
  log "Creating database '${IC_DB_NAME}'..."
  sudo -u postgres createdb -O "${IC_DB_USER}" "${IC_DB_NAME}"
  ok "Database '${IC_DB_NAME}' created (owner: ${IC_DB_USER})"
fi

# ── pgvector extension ────────────────────────────────────────────────────────
step "pgvector extension"

# Check if pgvector is already available
if psql -d "${IC_DB_NAME}" -tAc "SELECT 1 FROM pg_available_extensions WHERE name='vector'" 2>/dev/null | grep -q 1; then
  ok "pgvector extension already available"
else
  log "Building pgvector from source (not available in AL2023 repos)..."

  # Build dependencies
  sudo dnf install -y gcc make postgresql15-server-devel >/dev/null 2>&1

  PGVECTOR_VERSION="0.8.0"
  PGVECTOR_DIR="$(mktemp -d)"

  curl -fsSL "https://github.com/pgvector/pgvector/archive/refs/tags/v${PGVECTOR_VERSION}.tar.gz" \
    -o "${PGVECTOR_DIR}/pgvector.tar.gz"
  tar xzf "${PGVECTOR_DIR}/pgvector.tar.gz" -C "${PGVECTOR_DIR}"

  (
    cd "${PGVECTOR_DIR}/pgvector-${PGVECTOR_VERSION}"
    # pg_config tells make where PG headers and lib dirs are
    PG_CONFIG="$(command -v pg_config || echo /usr/bin/pg_config)"
    make PG_CONFIG="${PG_CONFIG}" -j"$(nproc)" 2>&1 | tail -3
    sudo make PG_CONFIG="${PG_CONFIG}" install 2>&1 | tail -3
  )

  rm -rf "${PGVECTOR_DIR}"
  ok "pgvector ${PGVECTOR_VERSION} built and installed"
fi

# Enable the vector extension in the ironclaw database
if psql -d "${IC_DB_NAME}" -tAc "SELECT 1 FROM pg_extension WHERE extname='vector'" 2>/dev/null | grep -q 1; then
  ok "pgvector extension already enabled in ${IC_DB_NAME}"
else
  log "Enabling pgvector extension in ${IC_DB_NAME}..."
  psql -d "${IC_DB_NAME}" -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null \
    || sudo -u postgres psql -d "${IC_DB_NAME}" -c "CREATE EXTENSION IF NOT EXISTS vector;"
  ok "pgvector extension enabled"
fi

# ── Install IronClaw binary ──────────────────────────────────────────────────
step "Installing IronClaw binary"

if command -v ironclaw &>/dev/null; then
  IC_EXISTING="$(ironclaw --version 2>/dev/null || echo unknown)"
  log "ironclaw already installed (${IC_EXISTING}) — reinstalling"
fi

# Detect architecture and pick the right release binary
ARCH="$(uname -m)"
case "${ARCH}" in
  aarch64|arm64) RELEASE_ARCH="aarch64-unknown-linux-musl" ;;
  x86_64)        RELEASE_ARCH="x86_64-unknown-linux-musl" ;;
  *)             fail "Unsupported architecture: ${ARCH}" ;;
esac

DOWNLOAD_URL="https://github.com/nearai/ironclaw/releases/latest/download/ironclaw-${RELEASE_ARCH}.tar.gz"
TEMP_DIR="$(mktemp -d)"

log "Downloading ironclaw-${RELEASE_ARCH} from GitHub releases..."
if ! curl -fsSL "${DOWNLOAD_URL}" -o "${TEMP_DIR}/ironclaw.tar.gz"; then
  rm -rf "${TEMP_DIR}"
  fail "Failed to download IronClaw from ${DOWNLOAD_URL}"
fi

# Extract and find the binary (tar layout may vary across releases)
tar xzf "${TEMP_DIR}/ironclaw.tar.gz" -C "${TEMP_DIR}"
IRONCLAW_BIN="$(find "${TEMP_DIR}" -name 'ironclaw' -type f -executable 2>/dev/null | head -1)"
if [[ -z "${IRONCLAW_BIN}" ]]; then
  # Fallback: binary might not have +x in the archive
  IRONCLAW_BIN="$(find "${TEMP_DIR}" -name 'ironclaw' -type f 2>/dev/null | head -1)"
fi
if [[ -z "${IRONCLAW_BIN}" ]]; then
  rm -rf "${TEMP_DIR}"
  fail "Could not find ironclaw binary in downloaded archive"
fi

mkdir -p "${HOME}/.local/bin"
install -m 755 "${IRONCLAW_BIN}" "${HOME}/.local/bin/ironclaw"
rm -rf "${TEMP_DIR}"

export PATH="${HOME}/.local/bin:$PATH"

if ! command -v ironclaw &>/dev/null; then
  fail "ironclaw command not found after install. Check PATH."
fi

IC_VERSION="$(ironclaw --version 2>/dev/null || echo unknown)"
ok "IronClaw installed: ${IC_VERSION}"

# ── Configure IronClaw ────────────────────────────────────────────────────────
step "Configuring IronClaw"

mkdir -p "${HOME}/.ironclaw"

# Write .env with bedrockify + PostgreSQL config — bypasses NEAR AI OAuth entirely
cat > "${HOME}/.ironclaw/.env" <<EOF
# IronClaw config — generated by loki-agent pack installer
# LLM: using bedrockify as OpenAI-compatible backend (no NEAR AI auth needed)
LLM_BACKEND=openai_compatible
LLM_BASE_URL=http://127.0.0.1:${BEDROCKIFY_PORT}/v1
LLM_API_KEY=not-needed
LLM_MODEL=${MODEL}

# Database: local PostgreSQL with pgvector
DATABASE_URL=postgresql://${IC_DB_USER}@localhost/${IC_DB_NAME}
EOF

chmod 600 "${HOME}/.ironclaw/.env"
ok "IronClaw config written: ${HOME}/.ironclaw/.env"
log "  LLM_BACKEND=openai_compatible → bedrockify:${BEDROCKIFY_PORT}"
log "  DATABASE_URL=postgresql://${IC_DB_USER}@localhost/${IC_DB_NAME}"

# ── Sanity check ─────────────────────────────────────────────────────────────
step "Sanity check"

IC_VER="$(ironclaw --version 2>/dev/null || ironclaw --help 2>/dev/null | head -1 || echo unknown)"
ok "ironclaw version: ${IC_VER}"

# Verify PostgreSQL is reachable
if psql -d "${IC_DB_NAME}" -c "SELECT 1" >/dev/null 2>&1; then
  ok "PostgreSQL connection: OK (${IC_DB_NAME})"
else
  warn "PostgreSQL connection failed — IronClaw may prompt for database setup"
fi

# Verify pgvector
if psql -d "${IC_DB_NAME}" -tAc "SELECT extversion FROM pg_extension WHERE extname='vector'" 2>/dev/null | grep -q .; then
  PGV_VER="$(psql -d "${IC_DB_NAME}" -tAc "SELECT extversion FROM pg_extension WHERE extname='vector'" 2>/dev/null)"
  ok "pgvector extension: v${PGV_VER}"
else
  warn "pgvector extension not detected — semantic search may not work"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
# ── Fix systemd service unit ─────────────────────────────────────────────────
step "Configuring systemd service"

SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
mkdir -p "${SYSTEMD_USER_DIR}"

cat > "${SYSTEMD_USER_DIR}/ironclaw.service" <<SVCEOF
[Unit]
Description=IronClaw daemon
After=network.target postgresql.service

[Service]
Type=simple
EnvironmentFile=${HOME}/.ironclaw/.env
Environment=CLI_ENABLED=false
ExecStart=${HOME}/.local/bin/ironclaw run --no-onboard
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
SVCEOF

# Enable lingering so user services start at boot without login
sudo loginctl enable-linger "${IC_DB_USER}" 2>/dev/null || true

# Reload and enable (but dont start — let bootstrap handle that)
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable ironclaw 2>/dev/null || true
ok "Systemd service installed with EnvironmentFile + --no-onboard"
write_done_marker "ironclaw"
printf "\n[PACK:ironclaw] INSTALLED — ironclaw CLI ready\n"
printf "  model: %s via bedrockify:%s\n" "${MODEL}" "${BEDROCKIFY_PORT}"
printf "  database: postgresql://%s@localhost/%s (pgvector enabled)\n" "${IC_DB_USER}" "${IC_DB_NAME}"
