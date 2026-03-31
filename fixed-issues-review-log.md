# Fixed Issues — feature/pack-system Review Log

## Round 1 (Opus)
- C1: Bootstrap marker mismatch — install.sh checked `/tmp/openclaw-setup-done` but bootstrap.sh writes `/tmp/loki-bootstrap-done`
- C2: DataVolumeSize MinValue=20 rejects 0 — hermes needs data_volume_gb=0, CFN/SAM/TF unconditionally create data volume
- C3: loginctl enable-linger never called by root — openclaw user systemd service killed when session ends
- H1: BootstrapScriptUrl parameter dead in all templates — points to deleted openclaw-bootstrap.sh
- H2: Secrets visible in cleartext in UserData (EC2 metadata, CFN console, TF state)
- H3: hermes `--model) shift 2` crashes if --model is last arg with no value
- H4: TF data volume unconditionally created — no count conditional for hermes (data_volume_gb=0)
- M1: bedrockify.service.tpl is dead code — install-daemon creates its own unit
- M2: parse_args() in common.sh defined but never used by any pack
- M3: model-mode naming inconsistency — manifest says provider-key, templates say api-key, config-gen checks api-key
- M4: loki:pack tag only on VPC in CFN/SAM but on all resources in TF — inconsistent
- M5: SSM log publisher may exceed 4KB Parameter Store limit with tail -200 lines
- L1: IsLiteLLM, IsApiKey, IsBedrock conditions defined but never used in CFN/SAM
- L2: openclaw-gateway.service.tpl hardcodes /home/ec2-user — breaks on Ubuntu
- L3: TF ssm_connect output hardcodes us-east-1 instead of using data source
- L4: git clone in UserData has no retry — GitHub blip kills entire bootstrap
- L5: Unquoted variables in UserData bootstrap call ($PACK_NAME, $DEFAULT_MODEL)

## Round 2 (Opus)
- C1: SAM template RequestQuotaIncreases indentation — nested under ProviderApiKey instead of top-level parameter
- H1: envsubst (gettext package) not installed on fresh AL2023 — pack installs fail with command not found
- H2: openclaw help text says model-mode provider-key but config-gen.py expects api-key
- M1: TF data volume race condition — EBS attached after boot, bootstrap may not find it in 30s window
- M2: hermes config files written without chmod 600 — .env and config.yaml world-readable
- M3: Gateway port default mismatch — CFN=18789, pack=3001, registry=3001
- M4: DataVolumeSize not auto-adjusted based on PackName — hermes deploys waste $8/mo on unused 80GB EBS
- L2: deploy/README.md references deleted openclaw-bootstrap.sh
- L3: No ERR trap handler in bootstrap.sh — cfn-signal never sent on failure, SSM publisher stuck
- L4: API keys visible in /proc/pid/cmdline via python3 positional args to config-gen.py

## My Review Fixes
- bedrockify install.sh missing binary install step — called require_cmd bedrockify before installing it
- --gw-port arg name mismatch — UserData sends --gw-port, openclaw expected --port only
- --litellm-base-url / --litellm-api-key / --provider-api-key arg name mismatches between UserData and pack
- PATH missing for pack execution — bootstrap.sh ran packs as ec2-user without mise/node on PATH
- hermes model mismatch — CFN passes Bedrock model ID overriding hermes OpenAI-style default
- TF dead var — bootstrap_url passed to templatefile but not referenced in userdata.sh.tpl

## Final Review Round (Opus)
- 3 dead files at deploy/ level — openclaw-config-gen.py, bedrock-motd.sh, litellm-setup.sh superseded by packs
- deploy/README.md stale — missing PackName docs, references deleted BootstrapScriptUrl
- Gateway token in systemd unit file at default 644 permissions — should be 600
- Noisy "Unknown argument" warnings from arg forwarding (~10+ per deploy) — catch-all only shifts 1
- TF providers.tf hardcodes us-east-1 — should respect user-selected region
- config-gen.py missing argv length guard

## Post-Refactor Review (Opus — JSON config)
- C1: Pack config JSON unreadable by ec2-user — root writes chmod 600 file, packs run as ec2-user, all config silently ignored
- H1: JSON config written via bash heredoc — injection-vulnerable if values contain quotes/backslashes
- M1: /tmp/loki-pack-config.json never cleaned up — secrets persist indefinitely
- M2: Secrets visible in process command line — config-gen.py passes secrets as positional args AND env vars
- M3: UserData doesn't pass --hermes-model or --bedrockify-port — can't customize from CFN parameters
- L1: CFN DataVolumeSize default 80GB regardless of pack — hermes users need to manually set 0
- L3: embed_model key not set in JSON config — bedrockify falls back to default
