# BOOTSTRAP-SECRETS-MANAGEMENT.md — Secrets Management & git-secrets Setup

> **These are standing rules, not a one-time setup.**
> Add them to AGENTS.md so they apply to every session.

## The Rules

1. **All secrets go in AWS Secrets Manager** — never in env files, `.bashrc`, code, or task definitions as plaintext environment variables
2. **All repos must have git-secrets pre-commit hooks** — prevents accidental secret commits
3. **New repos get git-secrets installed immediately** on first clone

---

## Part 1: git-secrets on Every Repo

### Install git-secrets (once per machine)

```bash
# Amazon Linux / AL2023
sudo yum install -y git-secrets 2>/dev/null || \
  (git clone https://github.com/awslabs/git-secrets /tmp/git-secrets && \
   cd /tmp/git-secrets && sudo make install)

# macOS
brew install git-secrets
```

### Add to a repo

```bash
cd /path/to/repo
git secrets --install          # adds pre-commit, commit-msg, prepare-commit-msg hooks
git secrets --register-aws     # adds AWS key patterns
```

### Add to ALL existing repos at once

```bash
# Run from the machine where repos are cloned
for dir in $(find ~ /mnt -maxdepth 5 -name ".git" -type d 2>/dev/null | sed 's|/.git||'); do
  echo "Installing git-secrets in $dir..."
  git -C "$dir" secrets --install -f 2>/dev/null
  git -C "$dir" secrets --register-aws 2>/dev/null
  echo "  ✅ done"
done
```

### Global install (applies to all future clones)

```bash
git secrets --install ~/.git-templates/git-secrets
git config --global init.templateDir ~/.git-templates/git-secrets
git secrets --register-aws --global
```

> After this, every `git clone` or `git init` automatically gets git-secrets hooks.

### Test it works

```bash
cd /path/to/repo
echo "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" > /tmp/test-secret.txt
git secrets --scan /tmp/test-secret.txt
# Expected: [ERROR] /tmp/test-secret.txt:1: ...
rm /tmp/test-secret.txt
```

---

## Part 2: GitHub Actions — Enforce in CI

Local hooks are not committed to the repo — anyone who clones without running `git secrets --install` has no protection. Add a workflow to enforce scanning in CI:

Create `.github/workflows/secret-scan.yml`:

```yaml
name: Secret Scan

on:
  push:
    branches: ["**"]
  pull_request:
    branches: ["**"]

jobs:
  git-secrets:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Install git-secrets
        run: |
          git clone https://github.com/awslabs/git-secrets.git /tmp/git-secrets
          cd /tmp/git-secrets && sudo make install

      - name: Register AWS patterns
        run: git secrets --register-aws --global

      - name: Scan for secrets
        run: git secrets --scan-history
```

This applies to **all repos** including markdown-only ones. Secrets can hide in docs too.

---

## Part 3: AWS Secrets Manager Patterns

### Store a secret

```bash
aws secretsmanager create-secret \
  --name /faststart/my-secret \
  --secret-string "the-value" \
  --region us-east-1
```

### Retrieve in scripts

```bash
MY_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id /faststart/my-secret \
  --query SecretString --output text --region us-east-1)
```

### Use in ECS task definitions

Reference via `secrets:` — never as plaintext `environment:`:

```json
"secrets": [
  {
    "name": "MY_SECRET",
    "valueFrom": "arn:aws:secretsmanager:us-east-1:ACCOUNT:secret:/faststart/my-secret"
  }
]
```

### Use in Lambda

```javascript
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
const sm = new SecretsManagerClient({ region: "us-east-1" });

let cached = null;
async function getSecret(name) {
  if (cached) return cached;
  const r = await sm.send(new GetSecretValueCommand({ SecretId: name }));
  cached = r.SecretString;
  return cached;
}
```

Always cache the result — Secrets Manager charges per API call.

### Naming convention

```
/faststart/<service>-<key>
/outline/<key>
/inceptionstack/<key>
```

---

## Part 3: Add git-secrets to InceptionStack Repos Now

Run this to install git-secrets hooks on all cloned inceptionstack repos:

```bash
export GH_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id /faststart/github-token --query SecretString --output text --region us-east-1)

REPOS=(
  embedrock
  loki-bootstrap
  loki-skills
  loki-template-brain
  admin-mission-control-ui
  solo-mission-control-ui
  standalone-remote-access-ui
)

TMPDIR=$(mktemp -d)
for repo in "${REPOS[@]}"; do
  echo "=== $repo ==="
  git clone "https://x-access-token:${GH_TOKEN}@github.com/inceptionstack/${repo}.git" "$TMPDIR/$repo" 2>/dev/null
  cd "$TMPDIR/$repo"
  git secrets --install -f
  git secrets --register-aws
  # Commit the hooks to .github/hooks or note them locally
  echo "  ✅ git-secrets installed locally in $repo"
  cd -
done
```

> Note: git-secrets hooks are local to each clone (not committed to the repo). Each developer/agent must run `git secrets --install` after cloning. Add this to onboarding docs.

---

## Part 4: What Loki Must Never Commit

git-secrets blocks AWS credentials automatically. Additionally, never commit:

- API keys, bearer tokens, passwords of any kind
- Database connection strings with credentials
- `.env` files
- Private keys (`.pem`, `.key`)
- Secrets Manager values fetched at runtime

If you need to test with a secret value, use a fake/placeholder and fetch the real value from Secrets Manager at runtime.

---

## Add to AGENTS.md

```markdown
## Security Rules
- ALL secrets in Secrets Manager — never in env files, .bashrc, code, or plaintext task def env vars
- ALL repos get git-secrets hooks on first clone: `git secrets --install && git secrets --register-aws`
- NEVER commit credentials, tokens, or connection strings with passwords
```

---

## No Marker File

These are permanent standing rules. Add them to AGENTS.md, not a one-time bootstrap.
