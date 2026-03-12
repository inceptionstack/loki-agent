# BOOTSTRAP-CODING-GUIDELINES.md — Coding Standards

> Add the **AGENTS.md snippet** at the bottom to your `AGENTS.md` — it's the token-optimized version Loki reads every session.
> This full file is the reference for why each rule exists.

---

## ❌ DON'Ts (enforce strictly, no exceptions)

**Secrets & Config**
- Never hardcode account IDs, ARNs, URLs, domains, or API keys in source code or buildspecs
- Never use `PLAINTEXT` values in CodeBuild env vars — always `PARAMETER_STORE` or `SECRETS_MANAGER`
- Never put secrets in `.env` files committed to git, CloudFormation templates, or task definition env vars

**Git & Dependencies**
- Never commit `node_modules/`, `dist/`, `build/`, `.next/`, `.cache/`, `coverage/`, `*.zip`, `*.tar.gz`, `.env*`, `.DS_Store`
- Never keep `node_modules/` in workspace repos — install on-demand, remove after
- Never manually deploy — everything through CI/CD pipelines (CodePipeline / GitHub Actions)

**Infrastructure**
- Never open SSH (port 22) to `0.0.0.0/0` — use SSM Session Manager
- Never use `x86` instance types when `arm64` (Graviton) is available — arm64 is default
- Never hardcode cross-account credentials — use IAM roles

**Notifications**
- Never leave a pipeline without build notifications wired up
- Never send raw internal metadata or stack traces to the operator — summarize them
- Never notify for routine/expected events (successful deploys, low findings) — only alert on failures and HIGH/CRITICAL issues

**Code**
- Never have a Lambda function without all config values injected via `process.env`
- Never have a frontend with hardcoded Cognito IDs, CloudFront domains, or API URLs
- Never deploy CloudFormation without validating first (`aws cloudformation validate-template`)

---

## ✅ DOs

**Secrets & Config**
- All secrets → AWS Secrets Manager (`/faststart/<project>/<key>`)
- All config → SSM Parameter Store (`/faststart/<project>/<key>`)
- Lambda config injected via CFN `Environment.Variables` using `!Ref`/`!Sub`
- Frontend config injected as `VITE_*` build vars from CodeBuild SSM params
- Use `AWS::AccountId`, `AWS::Region`, `AWS::StackName` pseudo-refs in CFN

**Git & Dependencies**
- Every repo: `.gitignore` with `node_modules/`, `dist/`, `.env`
- Every repo: `README.md` with architecture + deployment instructions
- Every repo: `git secrets --install && git secrets --register-aws` on first clone
- Lambda zips contain only bundled output (e.g. `index.mjs`) — never `node_modules/`

**Infrastructure**
- IaC first — CloudFormation or CDK, no click-ops
- Graviton/arm64 instance types by default (t4g, m7g, c7g)
- SSM `AmazonSSMManagedInstanceCore` on every EC2 IAM role
- CloudFront for all public HTTPS endpoints
- Cognito for all auth (OIDC)
- Encrypt all storage: EBS, Aurora, S3

**Notifications**
- Every CodePipeline: wire up EventBridge → pipeline notifier Lambda → Telegram + OpenClaw system event
- Every GitHub repo: register webhook → API Gateway → webhook Lambda → Telegram
- Pipeline failure → Loki auto-investigates (checks CodeBuild logs, fixes, pushes)
- Pipeline success when a task was waiting → move task to done, notify operator
- See `BOOTSTRAP-PIPELINE-NOTIFICATIONS.md` for setup

**CloudFront SPAs**
- Add CloudFront Function on `viewer-request` to rewrite paths for S3 OAC (S3 REST API doesn't auto-resolve `index.html` for subdirs)
- OAuth callbacks: use standalone plain HTML + vanilla JS in `public/auth/callback/index.html` — not React/Next.js pages (hydration errors kill all JS)
- Always invalidate `/*` after deploy

**Naming**
- Resources: `{project}-{resource}` (e.g. `outline-alb`)
- IAM roles: `{project}-{purpose}-role`
- Security groups: `{project}-{layer}-sg`
- SSM params: `/faststart/{project}/{key}`

---

## AGENTS.md Snippet (token-optimized — add this)

```markdown
## Coding Rules

### ❌ Never
- Hardcode account IDs, ARNs, URLs, secrets in source or buildspecs
- Commit node_modules/, dist/, .env*, *.zip, build artifacts
- Keep node_modules/ in workspace repos
- Manual deploys — always use CI/CD pipelines
- SSH open to 0.0.0.0/0 — use SSM
- x86 when arm64 is available
- PLAINTEXT values in CodeBuild — use PARAMETER_STORE/SECRETS_MANAGER

### ✅ Always
- Secrets → Secrets Manager, config → SSM Parameter Store
- Lambda config injected via CFN Environment.Variables
- Frontend config as VITE_* build vars from SSM
- .gitignore with node_modules/, dist/, .env in every repo
- README.md with architecture + deploy steps in every repo
- git secrets --install && git secrets --register-aws on first clone
- IaC first (CFN/CDK), Graviton arm64 by default, CloudFront for HTTPS, Cognito for auth
- Validate CFN before deploy: aws cloudformation validate-template
- Every CodePipeline: EventBridge → notifier Lambda → Telegram + OpenClaw system event
- Every GitHub repo: webhook → API Gateway → webhook Lambda → Telegram
- Pipeline failure → auto-investigate and fix; pipeline success (task waiting) → mark done, notify operator
- CloudFront SPA: viewer-request Function for path rewriting, plain HTML for OAuth callbacks, invalidate /* after deploy
```
