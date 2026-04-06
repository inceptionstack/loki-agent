# Upstream Fixes Needed: OpenClaw + pi-coding-agent Bedrock Auth

OpenClaw + pi-coding-agent fail when using AWS Bedrock with EC2 instance-profile auth (IMDS).
The AWS SDK credential chain works fine, but the auth pre-flight checks reject it before any request is made.

We currently patch these at install time (`packs/openclaw/resources/patch-pi-agent.py`), but
these patches are overwritten on every OpenClaw update.

## Issue 1: pi-coding-agent `hasConfiguredAuth()` rejects AWS SDK auth

**File:** `src/core/model-registry.ts` (dist: `dist/core/model-registry.js`)

**Problem:** `hasConfiguredAuth()` only checks `authStorage.hasAuth()` and `providerRequestConfigs.apiKey`. Neither is set for AWS SDK auth via instance profile. This causes "No API key found for amazon-bedrock" before any API request is made.

**Fix:** Return `true` when the provider is `amazon-bedrock` and the config uses `auth: "aws-sdk"`.

```typescript
// In hasConfiguredAuth():
if (this.providerId === "amazon-bedrock") return true;
```

**Why:** Bedrock auth uses AWS SDK signing (SigV4), not API keys. The SDK resolves credentials from the instance metadata service (IMDS) at request time. There's no key to pre-check.

---

## Issue 2: pi-coding-agent `_getRequiredRequestAuth()` throws on undefined apiKey

**File:** `src/core/agent-session.ts` (dist: `dist/core/agent-session.js`)

**Problem:** `_getRequiredRequestAuth()` throws when `getApiKeyAndHeaders()` returns `ok: true` but no `apiKey`. Bedrock uses AWS SDK signing (no API key needed), but this code path doesn't account for it.

**Fix:** Early return for `amazon-bedrock` provider with `{ apiKey: undefined, headers }`.

```typescript
// In _getRequiredRequestAuth():
if (this.providerId === "amazon-bedrock") {
  const authResult = await this._getRequestAuth?.() || { ok: true, headers: {} };
  return { apiKey: undefined, headers: authResult.headers || {} };
}
```

**Why:** The Bedrock provider adapter handles auth via the AWS SDK at the HTTP layer (SigV4 signing). It never needs an API key injected by the session.

---

## Issue 3 (Root Cause): OpenClaw auth-controller doesn't inject SDK auth into pi's authStorage

**File:** `src/agents/pi-embedded-runner/run/auth-controller.ts`

**Problem:** OpenClaw's auth controller correctly resolves AWS SDK auth (returns `{ mode: "aws-sdk", source: "..." }` from `resolveAwsSdkAuthInfo()`), but does an early return at ~line 329-337 without calling `setRuntimeApiKey()`. This means pi's `authStorage` never learns about Bedrock credentials.

**Proper fix:** When auth mode is `aws-sdk`, the auth controller should either:
1. Call `setRuntimeApiKey()` with a sentinel value that pi recognizes as "use SDK signing", or
2. Set a flag on the provider config that pi checks in `hasConfiguredAuth()` and `_getRequiredRequestAuth()`

This would eliminate the need for patches #1 and #2.

---

## Issue 4: `resolveAwsSdkEnvVarName()` doesn't detect IMDS

**File:** `src/agents/model-auth-runtime-shared.ts`

**Problem:** `resolveAwsSdkEnvVarName()` checks for `AWS_BEARER_TOKEN_BEDROCK`, `AWS_ACCESS_KEY_ID`+`AWS_SECRET_ACCESS_KEY`, and `AWS_PROFILE`. If none are set, it returns `undefined`. EC2 instances with IAM roles don't need any env vars — the SDK discovers credentials via IMDS automatically.

**Current workaround:** We set `AWS_PROFILE=default` in `/etc/profile.d/` and the systemd service unit, which triggers the env var check and lets the SDK fall through to IMDS.

**Proper fix:** The fallback in `resolveAwsSdkAuthInfo()` already returns `{ mode: "aws-sdk", source: "aws-sdk default chain" }` when no env vars are found — this is correct. The issue is upstream in the auth controller (Issue 3) not propagating this to pi.

---

## Environment

- OpenClaw version: latest (as of 2026-04-06)
- pi-coding-agent version: 0.65.0
- Platform: Amazon Linux 2023 on EC2 with IAM instance profile
- Auth method: Bedrock via IMDS (no API keys, no env vars)
- Config: `models.providers.amazon-bedrock.auth: "aws-sdk"`

## Reproduction

1. Launch EC2 instance with IAM role that has Bedrock access
2. Install OpenClaw: `npm install -g openclaw`
3. Configure with `auth: "aws-sdk"` for amazon-bedrock provider
4. Run `openclaw tui` — fails with "No API key found for amazon-bedrock"
5. Set `AWS_PROFILE=default` — still fails (auth pre-flight in pi rejects it)
6. Apply patches to model-registry.js and agent-session.js — works
