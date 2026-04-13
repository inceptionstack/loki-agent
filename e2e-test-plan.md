# E2E Test Plan — `feat/provider-packs` Branch

**Goal:** Validate all wizard flows before merging to `main`.
**Date:** 2026-04-13
**Tester:** _(fill in)_

---

## Legend

- ✅ = Passed
- ❌ = Failed (add notes)
- ⏭️ = Skipped (explain why)
- 🔲 = Not yet tested

---

## 1. Wizard CLI Infrastructure

### 1.1 Argument Parsing & Help
- [ ] `wizard.sh --help` prints usage with all flags
- [ ] `wizard.sh --dry-run` accepted
- [ ] `wizard.sh --non-interactive` / `-y` accepted
- [ ] `wizard.sh --scenario 1` accepted
- [ ] `wizard.sh --env-name my-env` sets environment name
- [ ] `wizard.sh --existing-vpc-id vpc-xxx` sets VPC mode to existing
- [ ] `wizard.sh --existing-subnet-id subnet-xxx` sets subnet
- [ ] `wizard.sh --unknown-flag` errors with "Unknown argument"
- [ ] `wizard.sh --scenario` (no value) errors with "requires a value"
- [ ] `wizard.sh --env-name` (no value) errors with "requires a value"

### 1.2 Gum Installation
- [ ] System with `gum` installed → uses system gum, no download
- [ ] System without `gum` → auto-installs to `/tmp/gum-bin/gum`
- [ ] `/tmp/gum-bin/gum` already present → reuses without re-downloading
- [ ] No internet access → fails gracefully with "Could not install gum"
- [ ] arm64 platform → downloads correct `Linux_arm64` binary
- [ ] x86_64 platform → downloads correct `Linux_x86_64` binary

### 1.3 Prerequisites
- [ ] Missing `jq` → fails with "jq is required"
- [ ] Missing `python3` → fails with "python3 is required"
- [ ] Missing `aws` CLI → VPC auto-detect falls back to new VPC gracefully

---

## 2. Interactive TUI Flows (Simple Mode)

### 2.1 Pack Selection
- [ ] Shows all agent packs: openclaw, claude-code, hermes, pi, ironclaw, nemoclaw, kiro-cli
- [ ] Selecting a pack updates defaults (instance type, volumes, ports)
- [ ] BACK returns to install mode selection

### 2.2 Environment Name
- [ ] Default pre-filled from pack name
- [ ] Custom name accepted
- [ ] Empty name rejected with validation error
- [ ] Invalid characters rejected

### 2.3 Profile Selection
- [ ] Shows available profiles for the selected pack
- [ ] Default is "builder"
- [ ] BACK returns to pack selection

### 2.4 Provider Selection
Only shows providers supported by the selected pack:

| Pack | Expected Providers |
|------|-------------------|
| openclaw | bedrock, anthropic-api, openai-api, openrouter, litellm |
| claude-code | bedrock, anthropic-api |
| hermes | bedrock, anthropic-api, openai-api, openrouter |
| pi | bedrock, openrouter, litellm |
| ironclaw | bedrock |
| nemoclaw | bedrock |
| kiro-cli | bedrock (own-cloud) |

- [ ] openclaw shows 5 providers
- [ ] claude-code shows 2 providers
- [ ] hermes shows 4 providers
- [ ] pi shows 3 providers
- [ ] ironclaw shows only bedrock
- [ ] nemoclaw shows only bedrock
- [ ] kiro-cli shows only own-cloud/bedrock
- [ ] BACK returns to profile selection

### 2.5 Provider Configuration

#### 2.5.1 Bedrock (IAM)
- [ ] Auth type defaults to `iam`
- [ ] Region selection shows allowed Bedrock regions
- [ ] No API key required
- [ ] NEXT proceeds to VPC step

#### 2.5.2 Bedrock (Bearer/API Key)
- [ ] Auth type can be switched to `bearer`
- [ ] API key field appears and is required
- [ ] Region still required
- [ ] Masked input for API key (dots/bullets)

#### 2.5.3 Anthropic API
- [ ] API key field required
- [ ] Key validated (starts with `sk-ant-`)
- [ ] No region required
- [ ] Empty key rejected

#### 2.5.4 OpenAI API
- [ ] API key field required
- [ ] Key validated (starts with `sk-`)
- [ ] No region required
- [ ] Empty key rejected

#### 2.5.5 OpenRouter
- [ ] API key field required
- [ ] Key validated (starts with `sk-or-`)
- [ ] No region required
- [ ] Empty key rejected

#### 2.5.6 LiteLLM (Proxy)
- [ ] Base URL field required
- [ ] URL validated (starts with `http://` or `https://`)
- [ ] No API key required (optional)
- [ ] Empty URL rejected

### 2.6 VPC Mode (Simple Flow)

#### 2.6.1 Auto-Detection — Existing Loki VPCs Found
- [ ] Queries for VPCs tagged `loki:managed=true`
- [ ] Shows list of found VPCs (ID, watermark, deploy-method, name)
- [ ] "Reuse an existing VPC?" prompt appears (default: yes)
- [ ] Accepting → auto-selects VPC (single) or shows chooser (multiple)
- [ ] Auto-finds public subnet (tagged "public" or MapPublicIpOnLaunch)
- [ ] Verifies subnet has IGW route (0.0.0.0/0 → igw-*)
- [ ] Sets vpcMode=existing, fills VPC ID and subnet ID

#### 2.6.2 Auto-Detection — No Existing VPCs
- [ ] No managed VPCs → silent proceed with new VPC
- [ ] vpcMode defaults to "new"
- [ ] No VPC ID or subnet ID set

#### 2.6.3 Auto-Detection — Decline Reuse
- [ ] User declines "Reuse?" → proceeds with new VPC
- [ ] vpcMode = "new"

#### 2.6.4 Auto-Detection — No Valid Subnet
- [ ] Existing VPC found but no public subnet with IGW route
- [ ] Warning: "Could not find a public subnet... proceeding with new VPC"
- [ ] Falls back to vpcMode=new

#### 2.6.5 CLI Override
- [ ] `--existing-vpc-id vpc-xxx --existing-subnet-id subnet-yyy` overrides auto-detect
- [ ] Prints "Using CLI-provided VPC settings"
- [ ] Skips all AWS API calls for VPC detection

### 2.7 Review Screen
- [ ] Shows summary of all selections
- [ ] Pack, provider, auth type, region, VPC mode, instance type all correct
- [ ] "Deploy" proceeds to deployment
- [ ] "Edit ..." options return to correct steps

---

## 3. Interactive TUI Flows (Advanced Mode)

### 3.1 Advanced Model Override
- [ ] Primary model override field works
- [ ] Fallback model override field works
- [ ] Empty = use pack default

### 3.2 Advanced Instance & Storage
- [ ] Instance type changeable (must be ARM64: t4g/m7g/c7g)
- [ ] x86 instance type rejected
- [ ] Root volume: 20-200 GB validated
- [ ] Data volume: 0 or 20-500 GB validated

### 3.3 Advanced Networking
- [ ] VPC Mode chooser: new / existing
- [ ] Existing VPC ID input
- [ ] Existing Subnet ID input
- [ ] Existing mode requires both IDs (validation)
- [ ] SSH Access: ssm-only (default) / keypair
- [ ] Key Pair Name field (only when keypair mode)
- [ ] Repo Branch field (default: main)
- [ ] Gateway Port field (default: 3001, validated as positive int)
- [ ] Telegram Token field (optional, masked)
- [ ] Allowed Chat IDs field (optional, comma-separated ints)

### 3.4 Advanced Deploy Method
- [ ] cfn-cli (default)
- [ ] cfn-console (shows params for manual console use)
- [ ] terraform (shows terraform vars)

### 3.5 Advanced Security Services
- [ ] All 5 enabled by default: Security Hub, GuardDuty, Inspector, Access Analyzer, Config
- [ ] Can individually toggle each
- [ ] Bedrock Model Access Form toggle
- [ ] Request Quota Increases toggle

---

## 4. Non-Interactive / CLI-Only Flows

### 4.1 Defaults (no flags beyond -y)
- [ ] `wizard.sh -y` → pack=openclaw, provider=bedrock/iam, auto-detect VPC
- [ ] Auto-detects existing Loki VPCs and reuses if found
- [ ] Generates valid CFN params and bootstrap command
- [ ] Proceeds to deploy_screen

### 4.2 With Environment Name
- [ ] `wizard.sh -y --env-name my-stack` → environmentName = "my-stack"

### 4.3 With Existing VPC Override
- [ ] `wizard.sh -y --existing-vpc-id vpc-xxx --existing-subnet-id subnet-yyy` → vpcMode=existing
- [ ] Skips auto-detection, uses provided values

### 4.4 Dry Run
- [ ] `wizard.sh --dry-run -y` → prints STATE_JSON, BOOTSTRAP_COMMAND, CFN_PARAMS, TERRAFORM_VARS
- [ ] Does NOT call `aws cloudformation create-stack`

---

## 5. Deployment Flows (deploy_screen)

### 5.1 CFN CLI Deploy
- [ ] Template size < 51200 bytes → uses `--template-body file://...`
- [ ] Template size > 51200 bytes → uploads to S3, uses `--template-url` with presigned URL
- [ ] S3 bucket auto-created if not exists (`<env>-cfn-templates-<account>`)
- [ ] `aws cloudformation create-stack` called with correct params
- [ ] Live event streaming: green ✓ for COMPLETE, blue + for IN_PROGRESS, red ✗ for FAILED
- [ ] On CREATE_COMPLETE: prints elapsed time, Instance ID, Public IP
- [ ] On FAILED/ROLLBACK: prints error, exits non-zero
- [ ] 30-minute timeout with clear message

### 5.2 CFN Console Deploy
- [ ] Prints CFN params as JSON for manual console paste
- [ ] Does NOT auto-deploy

### 5.3 Terraform Deploy
- [ ] Prints Terraform vars as JSON
- [ ] Does NOT auto-deploy

### 5.4 Dry Run Deploy
- [ ] Prints state, bootstrap command, CFN params, Terraform vars
- [ ] No AWS API calls made

---

## 6. Built-in Scenarios (Dry-Run Sweep)

All 19 scenarios must pass `--dry-run --non-interactive --scenario N`:

| # | Name | Pack | Provider | Auth | Status |
|---|------|------|----------|------|--------|
| 1 | simple-bedrock-iam | openclaw | bedrock | iam | 🔲 |
| 2 | simple-anthropic | openclaw | anthropic-api | api-key | 🔲 |
| 3 | simple-openai | openclaw | openai-api | api-key | 🔲 |
| 4 | simple-openrouter | openclaw | openrouter | api-key | 🔲 |
| 5 | simple-litellm | openclaw | litellm | proxy | 🔲 |
| 6 | hermes-anthropic | hermes | anthropic-api | api-key | 🔲 |
| 7 | hermes-openrouter | hermes | openrouter | api-key | 🔲 |
| 8 | claude-code-bedrock | claude-code | bedrock | iam | 🔲 |
| 9 | claude-code-anthropic | claude-code | anthropic-api | api-key | 🔲 |
| 10 | pi-openrouter | pi | openrouter | api-key | 🔲 |
| 11 | hermes-bedrock | hermes | bedrock | iam | 🔲 |
| 12 | hermes-openai | hermes | openai-api | api-key | 🔲 |
| 13 | pi-bedrock | pi | bedrock | iam | 🔲 |
| 14 | pi-litellm | pi | litellm | proxy | 🔲 |
| 15 | ironclaw-bedrock | ironclaw | bedrock | iam | 🔲 |
| 16 | nemoclaw-bedrock | nemoclaw | bedrock | iam | 🔲 |
| 17 | kiro-cli | kiro-cli | own-cloud | — | 🔲 |
| 18 | advanced-model-override | openclaw | bedrock | iam | 🔲 |
| 19 | minimal | openclaw | bedrock | iam | 🔲 |

---

## 7. E2E Deploy Tests (Real CFN Stacks)

### 7.1 Deploy into Existing VPC (auto-detect)
- [ ] `wizard.sh -y --env-name e2e-existing-vpc`
- [ ] Auto-detects VPC tagged `loki:managed=true`
- [ ] Auto-selects public subnet with IGW route
- [ ] CFN stack creates successfully (CREATE_COMPLETE)
- [ ] Instance boots, bootstrap completes (check `/var/log/loki-bootstrap.log`)
- [ ] Gateway health check passes (`curl localhost:3001/health`)
- [ ] Agent responds to `openclaw agent --agent main --message "Hello"`
- [ ] Stack teardown: `aws cloudformation delete-stack`

### 7.2 Deploy into Existing VPC (CLI override)
- [ ] `wizard.sh -y --env-name e2e-cli-vpc --existing-vpc-id <id> --existing-subnet-id <id>`
- [ ] Uses provided VPC/subnet (no auto-detect)
- [ ] CFN stack creates successfully
- [ ] Agent responds

### 7.3 Deploy into New VPC
- [ ] `wizard.sh -y --env-name e2e-new-vpc` (in account with no `loki:managed` VPCs, or decline reuse)
- [ ] Creates new VPC, subnets, IGW, route tables
- [ ] CFN stack creates successfully
- [ ] Agent responds
- [ ] Stack teardown cleans up VPC resources

### 7.4 Provider-Specific Deploy Tests

#### 7.4.1 Bedrock IAM (Default)
- [ ] `wizard.sh -y --env-name e2e-bedrock-iam`
- [ ] Provider = bedrock, auth = iam
- [ ] Instance profile has Bedrock permissions
- [ ] Agent can call Bedrock models

#### 7.4.2 Bedrock Bearer (API Key)
- [ ] `wizard.sh` → select bedrock → switch auth to bearer → enter API key
- [ ] API key stored in SSM/Secrets Manager (not plaintext in CFN)
- [ ] Agent authenticates via bearer token

#### 7.4.3 Anthropic API
- [ ] `wizard.sh` → select anthropic-api → enter API key
- [ ] CFN param `ProviderApiKey` set
- [ ] Agent calls Anthropic API directly (not via Bedrock)

#### 7.4.4 OpenAI API
- [ ] `wizard.sh` → select openai-api → enter API key
- [ ] Agent calls OpenAI API

#### 7.4.5 OpenRouter
- [ ] `wizard.sh` → select openrouter → enter API key
- [ ] Agent calls OpenRouter API

### 7.5 Pack-Specific Deploy Tests

#### 7.5.1 openclaw
- [ ] Deploys with gateway on port 3001
- [ ] Brain files installed in workspace
- [ ] Bedrockify proxy running (if bedrock provider)

#### 7.5.2 claude-code
- [ ] Deploys with t4g.large (smaller instance)
- [ ] Claude Code agent functional

#### 7.5.3 hermes
- [ ] Deploys with hermes model config
- [ ] Hermes agent functional

#### 7.5.4 kiro-cli
- [ ] Deploys with own-cloud provider
- [ ] No external provider API calls needed

---

## 8. Validation & Error Handling

### 8.1 CFN Parameter Validation
- [ ] No `ProviderBaseUrl` parameter emitted (removed — not in template)
- [ ] `LiteLLMBaseUrl` only set when provider is litellm
- [ ] `ExistingVpcId` and `ExistingSubnetId` both set or both empty
- [ ] Template `Rules` section validates VPC+Subnet pairing
- [ ] All boolean params emitted as `"true"` / `"false"` strings

### 8.2 Bootstrap Command Validation
- [ ] `--existing-vpc-id` and `--existing-subnet-id` included when vpcMode=existing
- [ ] `--existing-vpc-id` NOT included when vpcMode=new
- [ ] `--provider-key` NOT included for bedrock/iam
- [ ] `--provider-key` included for anthropic/openai/openrouter
- [ ] `--litellm-base-url` included for litellm

### 8.3 Review Validation
- [ ] `wizard_validate_review_state()` catches missing VPC+Subnet when vpcMode=existing
- [ ] Catches invalid gateway port
- [ ] Catches invalid environment name
- [ ] Catches mismatched pack/provider combination

### 8.4 Edge Cases
- [ ] Invalid scenario number (--scenario 99) → "Unknown scenario" error
- [ ] Ctrl+C during wizard → clean exit with partial command shown
- [ ] Duplicate stack name → CFN "already exists" error surfaced
- [ ] IAM permission denied → error surfaced (not silent fail)

---

## 9. Regression Checks

- [ ] All 19 built-in scenarios still pass after changes
- [ ] `bash -n deploy/wizard.sh` syntax check passes
- [ ] `bash -n deploy/lib/wizard-command.sh` syntax check passes
- [ ] `bash -n deploy/lib/wizard-validate.sh` syntax check passes
- [ ] `bash -n deploy/lib/wizard-data.sh` syntax check passes
- [ ] `bash -n deploy/lib/wizard-state.sh` syntax check passes
- [ ] `bash -n deploy/lib/wizard-ui.sh` syntax check passes
- [ ] Main branch `install.sh` still works (not broken by wizard changes)

---

## Test Results Summary

| Category | Total | Passed | Failed | Skipped |
|----------|-------|--------|--------|---------|
| CLI Infrastructure | 19 | 16 | | | |
| Simple TUI Flows | 64 | 35 | | | |
| Advanced TUI Flows | 24 | 18 | | | |
| Non-Interactive Flows | 9 | 6 | | | |
| Deploy Flows | 14 | 8 | | | |
| Scenario Sweep | 19 | | | |
| E2E Deploy Tests | 40 | 16 | | | |
| Validation & Errors | 18 | 14 | | | |
| Regression | 8 | | | |
| **TOTAL** | **249** | | | |

---

## Notes

- E2E deploy tests create real AWS resources and incur costs. Tear down stacks after testing.
- API key tests require valid keys for each provider.
- LiteLLM tests require a running LiteLLM proxy endpoint.
- Bedrock bearer tests require a Bedrock API key (see `bedrock-api-keys` skill).
- Test on both arm64 (primary target) and x86_64 if possible.

---

## 10. Review Findings (from Codex Code Review)

The following gaps were identified by automated code review and should be addressed:

### 10.1 Provider Selection Behavior (Correction)
The wizard does NOT hide unsupported providers — it shows all 5 and marks unsupported ones as disabled/greyed out. kiro-cli skips provider selection entirely and hard-sets `own-cloud`.
- [ ] Unsupported providers appear disabled (not hidden) for each pack
- [ ] kiro-cli skips provider step entirely (no chooser shown)

### 10.2 Provider Auth Corrections
- [ ] OpenRouter keys: validated by length only (≥10 chars), NO `sk-or-` prefix check
- [ ] Bedrock bearer tokens: validated with `ABS-` prefix (not generic API key)
- [ ] Anthropic keys: `sk-ant-` prefix validated
- [ ] OpenAI keys: length-only validation (no `sk-` prefix enforcement in wizard)

### 10.3 Missing Simple-Mode Sub-Flows
- [ ] Primary Model Override field present in simple-mode provider config (all providers)
- [ ] LiteLLM optional API key input field (separate from base URL)

### 10.4 Missing Advanced-Mode Sub-Flows
- [ ] Context Window override field
- [ ] Max Output Tokens override field
- [ ] Hermes Model override field (hermes pack only)

### 10.5 NemoClaw Profile Restriction
- [ ] NemoClaw only allows `personal_assistant` profile — others rejected
- [ ] personal_assistant profile disables security service defaults

### 10.6 kiro-cli Special Behavior
- [ ] kiro-cli skips provider selection, sets provider=own-cloud
- [ ] kiro-cli post-install review note shown in review screen

### 10.7 CFN Template Parameters Not Covered
- [ ] `ModelMode` param correctly set (bedrock/api-key/litellm) based on provider
- [ ] `LiteLLMApiKey` param set when LiteLLM API key provided
- [ ] `LiteLLMModel` param set when LiteLLM model override provided
- [ ] `ProviderApiKeySecretArn` path tested (secret ARN instead of plaintext key)

### 10.8 Missing Edge Cases
- [ ] `--existing-vpc-id` without `--existing-subnet-id` → should error or warn
- [ ] `--existing-subnet-id` without `--existing-vpc-id` → should error or warn
- [ ] Environment name > 24 chars → CFN rejects (AllowedPattern + MaxLength)
- [ ] Environment name with uppercase → CFN rejects (AllowedPattern: `[a-z0-9-]+`)
- [ ] Non-interactive path skips review validation — verify CFN template Rules catch issues
- [ ] SSH Access = keypair with blank key pair name
- [ ] Scenario invocation by name (not just number): `--scenario simple-bedrock-iam`

### 10.9 Main Branch install.sh Regression
- [ ] `install.sh -y` still works (non-interactive)
- [ ] `install.sh --pack openclaw` still works
- [ ] `install.sh --method cfn` still works
- [ ] `install.sh --profile builder` still works
- [ ] `install.sh --simple` still works
- [ ] `install.sh --advanced` still works
- [ ] `install.sh --debug-in-repo` still works
- [ ] VPC auto-detection in install.sh unchanged by wizard changes
