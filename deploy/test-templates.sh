#!/usr/bin/env bash
# deploy/test-templates.sh — Validate that all pack-system changes are in place
# Run from the repo root: bash deploy/test-templates.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFN_TEMPLATE="$REPO_ROOT/deploy/cloudformation/template.yaml"
SAM_TEMPLATE="$REPO_ROOT/deploy/sam/template.yaml"
TF_VARS="$REPO_ROOT/deploy/terraform/variables.tf"
TF_MAIN="$REPO_ROOT/deploy/terraform/main.tf"
TF_OUTPUTS="$REPO_ROOT/deploy/terraform/outputs.tf"
TF_USERDATA="$REPO_ROOT/deploy/terraform/userdata.sh.tpl"
INSTALL_SH="$REPO_ROOT/install.sh"

PASS=0
FAIL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}✗${NC} $1"; FAIL=$((FAIL+1)); }

check_contains() {
  local file="$1" pattern="$2" desc="$3"
  if python3 -c "
import sys
pattern = sys.argv[1]
with open(sys.argv[2]) as f:
    content = f.read()
sys.exit(0 if pattern in content else 1)
" "$pattern" "$file" 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc  [missing: $pattern in $(basename "$file")]"
  fi
}

echo ""
echo -e "${BOLD}=== Loki Agent — Pack System Template Tests ===${NC}"
echo ""

# ── CloudFormation ──────────────────────────────────────────────────────────
echo -e "${BOLD}CloudFormation (deploy/cloudformation/template.yaml)${NC}"
check_contains "$CFN_TEMPLATE" "PackName:" "CFN: PackName parameter defined"
check_contains "$CFN_TEMPLATE" "openclaw" "CFN: PackName AllowedValues includes openclaw"
check_contains "$CFN_TEMPLATE" "hermes" "CFN: PackName AllowedValues includes hermes"
check_contains "$CFN_TEMPLATE" "- PackName" "CFN: PackName in Metadata ParameterGroups"
check_contains "$CFN_TEMPLATE" "loki:pack" "CFN: VPC has loki:pack tag"
check_contains "$CFN_TEMPLATE" "git clone --depth 1" "CFN: UserData uses git clone"
check_contains "$CFN_TEMPLATE" "deploy/bootstrap.sh" "CFN: UserData calls bootstrap.sh"
check_contains "$CFN_TEMPLATE" "--pack" "CFN: UserData passes --pack flag"
check_contains "$CFN_TEMPLATE" "Deployed agent pack" "CFN: PackName in Outputs"

echo ""

# ── SAM ─────────────────────────────────────────────────────────────────────
echo -e "${BOLD}SAM (deploy/sam/template.yaml)${NC}"
check_contains "$SAM_TEMPLATE" "PackName:" "SAM: PackName parameter defined"
check_contains "$SAM_TEMPLATE" "hermes" "SAM: PackName AllowedValues includes hermes"
check_contains "$SAM_TEMPLATE" "- PackName" "SAM: PackName in Metadata ParameterGroups"
check_contains "$SAM_TEMPLATE" 'loki:pack' "SAM: VPC has loki:pack tag"
check_contains "$SAM_TEMPLATE" 'git clone --depth 1' "SAM: UserData uses git clone"
check_contains "$SAM_TEMPLATE" 'deploy/bootstrap.sh' "SAM: UserData calls bootstrap.sh"
check_contains "$SAM_TEMPLATE" '--pack' "SAM: UserData passes --pack flag"
check_contains "$SAM_TEMPLATE" 'Deployed agent pack' "SAM: PackName in Outputs"

echo ""

# ── Terraform variables.tf ──────────────────────────────────────────────────
echo -e "${BOLD}Terraform (deploy/terraform/variables.tf)${NC}"
check_contains "$TF_VARS" 'variable "pack_name"' "TF: pack_name variable defined"
check_contains "$TF_VARS" '"openclaw"' "TF: pack_name default is openclaw"
check_contains "$TF_VARS" '"hermes"' "TF: pack_name validation includes hermes"
check_contains "$TF_VARS" 'validation' "TF: pack_name has validation block"
check_contains "$TF_VARS" 'contains' "TF: pack_name validation uses contains()"

echo ""

# ── Terraform main.tf ────────────────────────────────────────────────────────
echo -e "${BOLD}Terraform (deploy/terraform/main.tf)${NC}"
check_contains "$TF_MAIN" "pack_name        = var.pack_name" "TF main: pack_name passed to userdata template"
check_contains "$TF_MAIN" '"loki:pack"' "TF main: loki:pack in loki_tags"

echo ""

# ── Terraform userdata.sh.tpl ────────────────────────────────────────────────
echo -e "${BOLD}Terraform (deploy/terraform/userdata.sh.tpl)${NC}"
check_contains "$TF_USERDATA" 'PACK_NAME' "TF userdata: PACK_NAME variable set"
check_contains "$TF_USERDATA" 'git clone --depth 1' "TF userdata: uses git clone"
check_contains "$TF_USERDATA" 'deploy/bootstrap.sh' "TF userdata: calls bootstrap.sh"
check_contains "$TF_USERDATA" '--pack' "TF userdata: passes --pack flag"

echo ""

# ── Terraform outputs.tf ────────────────────────────────────────────────────
echo -e "${BOLD}Terraform (deploy/terraform/outputs.tf)${NC}"
check_contains "$TF_OUTPUTS" '"pack_name"' "TF outputs: pack_name output defined"
check_contains "$TF_OUTPUTS" 'var.pack_name' "TF outputs: pack_name references var"

echo ""

# ── install.sh ───────────────────────────────────────────────────────────────
echo -e "${BOLD}install.sh${NC}"
check_contains "$INSTALL_SH" 'Agent to deploy' "install.sh: pack selection menu header"
check_contains "$INSTALL_SH" 'OpenClaw' "install.sh: OpenClaw option in menu"
check_contains "$INSTALL_SH" 'Hermes' "install.sh: Hermes option in menu"
check_contains "$INSTALL_SH" 'PACK_NAME=' "install.sh: PACK_NAME variable set"
check_contains "$INSTALL_SH" 'PackName' "install.sh: PackName in PARAM_CFN_NAMES"
check_contains "$INSTALL_SH" 'pack_name' "install.sh: pack_name in PARAM_TF_NAMES"
check_contains "$INSTALL_SH" 't4g.medium' "install.sh: hermes default size logic present"

echo ""
echo -e "${BOLD}─────────────────────────────────────────────────${NC}"
echo -e "  Passed: ${GREEN}${PASS}${NC}  Failed: ${RED}${FAIL}${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
  echo -e "${RED}✗ Some checks failed — review output above${NC}"
  exit 1
else
  echo -e "${GREEN}✓ All checks passed!${NC}"
  exit 0
fi
