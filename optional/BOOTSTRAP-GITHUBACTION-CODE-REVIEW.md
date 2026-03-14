# BOOTSTRAP-GITHUBACTION-CODE-REVIEW.md — Automatic Code Review with Claude Code

> Add this to any repo in the inceptionstack org to get automatic AI code review on PRs and commits.

## Overview

Two GitHub Actions workflows provide automatic code review using Claude Code backed by Amazon Bedrock:

1. **`claude-review.yml`** — Reviews every PR. Also responds to `@claude` mentions in PR comments.
2. **`commit-review.yml`** — Reviews every push to `main`. Creates a GitHub issue + Telegram alert if critical issues are found.

Both use Bedrock via org-level secrets — no per-repo setup needed.

## Prerequisites

The following must be set at the **org level** in GitHub (Settings → Secrets and variables → Actions):

**Secrets:**
- `AWS_BEARER_TOKEN_BEDROCK` — Bedrock API bearer token
- `TELEGRAM_BOT_TOKEN` — Telegram bot token (for critical finding alerts)
- `TELEGRAM_CHAT_ID` — Telegram chat ID to notify

**Variables:**
- `REVIEW_CLAUDE_MODEL` — Model ID to use (e.g. `us.anthropic.claude-sonnet-4-6`). Falls back to `us.anthropic.claude-sonnet-4-6` if unset.

These are inherited by all repos in the org automatically.

## Step 1: Add PR Review Workflow

Create `.github/workflows/claude-review.yml`:

```yaml
name: Claude Code Review

on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened]
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]

jobs:
  pr-review:
    if: |
      (github.event_name == 'pull_request') ||
      (github.event_name == 'issue_comment' && contains(github.event.comment.body, '@claude')) ||
      (github.event_name == 'pull_request_review_comment' && contains(github.event.comment.body, '@claude'))
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
      issues: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 1

      - uses: anthropics/claude-code-action@v1
        with:
          use_bedrock: "true"
          github_token: ${{ secrets.GITHUB_TOKEN }}
          track_progress: "true"
          prompt: |
            REPO: ${{ github.repository }}
            PR NUMBER: ${{ github.event.pull_request.number }}

            Review this pull request for code quality, correctness, and security.
            Be concise but thorough. Flag any bugs, security issues, or anti-patterns.
            Suggest improvements where appropriate.
            Use inline comments for specific line-level issues.
            Use a top-level comment for the overall summary.
          claude_args: |
            --max-turns 20
            --model ${{ vars.REVIEW_CLAUDE_MODEL || 'us.anthropic.claude-sonnet-4-6' }}
            --allowedTools "mcp__github_inline_comment__create_inline_comment,Bash(gh pr comment:*),Bash(gh pr diff:*),Bash(gh pr view:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(cat:*),Read"
        env:
          AWS_BEARER_TOKEN_BEDROCK: ${{ secrets.AWS_BEARER_TOKEN_BEDROCK }}
          AWS_REGION: us-east-1
          CLAUDE_CODE_USE_BEDROCK: "1"
```

**Customizing the prompt for your stack:** Replace the generic prompt with language/framework-specific instructions. Examples:

```yaml
# Go
prompt: |
  Review this Go PR for: error handling (no silent drops), resource leaks,
  race conditions, input validation, idiomatic Go patterns.

# TypeScript/React
prompt: |
  Review this TypeScript/React PR for: type safety, hook rules,
  unnecessary re-renders, accessibility, security (XSS, CSRF).
```

## Step 2: Add Commit Review Workflow

Create `.github/workflows/commit-review.yml`:

```yaml
name: Commit Review

on:
  push:
    branches: [main]

jobs:
  commit-review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      issues: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2

      - name: Install Claude Code
        run: npm install -g @anthropic-ai/claude-code@latest

      - name: Review commit with Claude
        id: review
        env:
          AWS_BEARER_TOKEN_BEDROCK: ${{ secrets.AWS_BEARER_TOKEN_BEDROCK }}
          AWS_REGION: us-east-1
          CLAUDE_CODE_USE_BEDROCK: "1"
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          SHORT_SHA=$(echo "${{ github.sha }}" | cut -c1-7)
          COMMIT_MSG="${{ github.event.head_commit.message }}"
          echo "short_sha=$SHORT_SHA" >> $GITHUB_OUTPUT

          # Skip review for workflow-only or doc-only changes
          CHANGED=$(git diff HEAD~1 --name-only 2>/dev/null || echo "")
          if ! echo "$CHANGED" | grep -qvE '\.github/|\.md$'; then
            echo "Skipping review — only workflow/doc changes"
            echo "skip=true" >> $GITHUB_OUTPUT
            exit 0
          fi

          DIFF=$(git diff HEAD~1)
          echo "Reviewing commit $SHORT_SHA..."

          REVIEW=$(claude --print --max-turns 5 --model ${{ vars.REVIEW_CLAUDE_MODEL || 'us.anthropic.claude-sonnet-4-6' }} \
            "Review this git diff for security vulnerabilities, bugs, and anti-patterns. Be concise. If no issues, say 'No issues found.' Do NOT suggest creating issues or PRs — just give the review.

          Commit: $SHORT_SHA
          Message: $COMMIT_MSG

          $DIFF") || true

          # Check for critical findings
          if echo "$REVIEW" | grep -qiE "critical|vulnerability|injection|hardcoded.*(secret|password|key)|RCE|remote code execution"; then
            ISSUE_URL=$(gh issue create \
              --title "🔍 Review finding in $SHORT_SHA" \
              --body "## Commit Review: \`$SHORT_SHA\`

          **Message:** $COMMIT_MSG
          **Author:** ${{ github.actor }}

          ---

          $REVIEW" \
              --label "review-finding" 2>&1)
            echo "issue_url=$ISSUE_URL" >> $GITHUB_OUTPUT
            echo "critical=true" >> $GITHUB_OUTPUT
            echo "$REVIEW" > /tmp/review.txt
          else
            echo "critical=false" >> $GITHUB_OUTPUT
          fi

      - name: Notify Telegram
        if: steps.review.outputs.critical == 'true' && secrets.TELEGRAM_BOT_TOKEN != '' && secrets.TELEGRAM_CHAT_ID != ''
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
        run: |
          MSG="🔍 *Code Review Finding*

          *Repo:* \`${{ github.repository }}\`
          *Commit:* \`${{ steps.review.outputs.short_sha }}\` by ${{ github.actor }}
          *Message:* ${{ github.event.head_commit.message }}

          Claude found critical issues and created an issue:
          ${{ steps.review.outputs.issue_url }}"

          curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="${MSG}" \
            -d parse_mode="Markdown" \
            -d disable_web_page_preview="true"
```

## How It Works

**PR review (`claude-review.yml`):**
- Triggers on every PR open, push, or reopen
- Uses `anthropics/claude-code-action@v1` to post inline comments + a summary comment
- Respond to `@claude` in any PR comment to ask follow-up questions or request re-review
- Claude has read-only access: can view diff, files, PR metadata — cannot push code

**Commit review (`commit-review.yml`):**
- Triggers on every push to `main`
- Skips automatically if the diff is only `.md` or `.github/` files
- Creates a GitHub issue labeled `review-finding` + sends Telegram alert only when Claude flags something critical (vulnerability, hardcoded secret, RCE, etc.)
- Non-critical reviews are logged in the Actions run but don't create noise

## Repos Using This Pattern

- `inceptionstack/admin-mission-control-ui`
- `inceptionstack/solo-mission-control-ui`
- `inceptionstack/loki-skills`
- `inceptionstack/embedrock`
