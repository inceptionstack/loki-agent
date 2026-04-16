# BOOTSTRAP-BEDROCK-BENCHMARK.md — Amazon Bedrock Model Latency Benchmarking

> **Applies to:** Any agent with AWS credentials (IAM role) and Python 3.10+

This bootstrap equips you to run rigorous, reproducible latency benchmarks comparing models on Amazon Bedrock — and optionally against the Anthropic Direct API. The methodology is battle-tested across Haiku, Sonnet, and Opus workloads at various payload sizes and regions.

---

## Agent Behavior — Assumption Sheet Before Execution

When a user asks you to run a benchmark (e.g. "benchmark Sonnet 3.7 vs 4.6 latency"), **do NOT start coding or running immediately**. Instead:

1. **Fill in an assumption sheet** from the variables below, using sensible defaults for anything the user didn't specify
2. **Present it to the user** as a numbered checklist for review
3. **Wait for explicit approval** (or corrections) before writing any code or making any API calls

### Assumption Sheet Template

Present this to the user, pre-filled with your best-guess defaults:

```
📋 Benchmark Plan — Please review before I start

1. Models: [e.g. Sonnet 3.7 vs Sonnet 4.6]
2. Bedrock model IDs: [e.g. us.anthropic.claude-sonnet-4-5-20250929-v1:0 vs us.anthropic.claude-sonnet-4-6-v1]
3. Inference profile type: [us cross-region / eu / global / in-region]
4. Region (Bedrock endpoint): [e.g. us-east-1]
5. Client location: [e.g. EC2 in us-east-1 — same region]
6. Streaming or non-streaming: [e.g. non-streaming]
7. Extended thinking: [Off / On with budget N tokens]
8. Prompt sizes to test: [e.g. small (~500 tok), medium (~2K tok), large (~10K tok)]
9. Expected output tokens (max_tokens): [e.g. 500 for small, 1000 for large]
10. Iterations per combination: [e.g. 10]
11. Concurrency: [e.g. 1 (sequential)]
12. Include Anthropic Direct API comparison: [Yes / No]
13. Prompt caching: [Off / On — if on, report cold vs warm separately]
14. Estimated cost: [$X.XX — will confirm exact estimate before running]
15. Output: [Markdown report + raw JSONL saved to results/]

⚠️ Assumptions I made (please verify):
- [e.g. "Using us. cross-region profile since you didn't specify — this routes across US regions"]
- [e.g. "Non-streaming since you didn't mention streaming — change if your production uses streaming"]
- [e.g. "No extended thinking — confirm if you want thinking enabled on either model"]
- [e.g. "10 iterations — increase to 20+ if you need tighter confidence intervals"]

Reply with OK to proceed, or tell me what to change.
```

After the benchmark completes, **always offer these two deliverables:**

```
✅ Benchmark complete! I can now prepare:

1. 📊 **Summary Report** (Markdown) — Key findings, comparison tables,
   methodology, caveats. Ready to share with stakeholders or attach to
   a support case. Includes all controlled variables so readers can
   assess validity.

2. 🔁 **Reproduce Script** (standalone Python) — A single self-contained
   script that anyone can run to reproduce these exact results.
   No external dependencies beyond `pip install anthropic boto3`.
   Includes inline comments explaining what each variable controls.
   Designed to be shared with teammates or AWS Support so they
   can run it in their own account and compare.

Want me to generate both?
```

### Reproduce Script Requirements

The standalone reproduce script must:
- Be a **single .py file** with no imports from your workspace — fully self-contained
- Include **all prompts inline** (no external files)
- Print a clear **header** with all test parameters before starting
- Print a **cost estimate** and require Enter to proceed
- Handle **rate limiting** gracefully (retry with backoff, log throttle events)
- Output a **formatted summary table** to stdout at the end
- Save **raw JSONL** results to a file for further analysis
- Include a docstring at the top explaining:
  - What it tests and why
  - How to run it (`python benchmark.py`)
  - Prerequisites (IAM permissions, pip install, region access)
  - How to interpret the results
  - Which variables to change for their specific scenario
- Use **argparse** so the user can easily change: models, region, iterations, streaming mode, max_tokens
- Default to sensible values that work out of the box with just IAM credentials
- **NOT** require an Anthropic API key unless `--include-direct` is passed

### Summary Report Requirements

The markdown report must include:
- **Test configuration** — every variable from the assumption sheet, explicitly stated
- **Results tables** — E2E latency (avg, P50, P95), TTFT if streaming, ms/output-token, OTPS
- **Delta analysis** — percentage differences between models with direction (faster/slower)
- **Key findings** — 3-5 bullet points summarizing the takeaway in plain language
- **Methodology notes** — how to reproduce, what was controlled, what wasn't
- **Caveats** — explicitly state limitations (e.g. "measured at low concurrency", "on-demand only", "single region")

### Default Assumptions (when user doesn't specify)

| Variable | Default | Rationale |
|----------|---------|-----------|
| Inference profile | `us.` cross-region | Most common production setup; higher throughput than in-region |
| Region | `us-east-1` | Most capacity, lowest latency for US-based instances |
| Streaming | Non-streaming | Simpler measurement; add streaming run if user needs TTFT |
| Thinking | Off | Unless user explicitly asks for reasoning/thinking comparison |
| Prompt sizes | Small + Medium + Large | Covers the range; skip XL unless user has large-context workloads |
| Iterations | 10 | Minimum for statistical significance; suggest 20 if user needs tight P95/P99 |
| Concurrency | 1 (sequential) | Baseline; suggest concurrent test as follow-up |
| Direct API | No | Only include if user explicitly wants Bedrock vs Direct comparison |
| Caching | Off | Unless user mentions caching or large repeated prompts |
| max_tokens | Matched to expected output | Never set arbitrary high values |

### When to push back

If the user asks for something that will produce misleading results, **say so**:
- "Compare Bedrock latency from my laptop" → Explain that internet variability will dominate; recommend EC2
- "Run 3 iterations" → Explain that <10 iterations won't give statistically meaningful P95/P99
- "Compare streaming TTFT vs non-streaming total" → Explain these are different metrics
- "Use max_tokens=100000" → Explain the quota reservation trap

---

## Diagnosing Latency Issues

When investigating a latency issue (e.g. "Claude on Bedrock is slower than on Anthropic Direct"), **don't jump to benchmarking**. First, characterize the problem and gather the right information.

### Step 1: Characterize the Invocation Profile

Performance depends entirely on the specific invocation profile. Public benchmarks sample with specific profiles that may not match your workload at all. Gather this information:

```
📋 Invocation Profile — Please fill in so we can investigate

1. Model ID used (full Bedrock model ID or inference profile ARN):
2. Inference profile type: [in-region / us / eu / global cross-region]
3. API: [Converse / ConverseStream / InvokeModel / InvokeModelWithResponseStream]
4. Streaming: [Yes / No]
5. Region(s) called:
6. Client location: [EC2 same-region / EC2 different-region / Lambda / on-prem / laptop]
7. Typical input token count:
8. Typical output token count:
9. max_tokens parameter value:
10. Extended thinking: [Off / On — budget?]
11. Prompt caching: [Off / On — hit rate?]
12. Guardrails attached: [Yes / No]
13. Concurrency: [single request / N concurrent — typical N?]
14. When the issue occurs: [specific times / always / intermittent]
15. Account ID + region (useful if opening an AWS Support case):
```

**Why every field matters:** A workload calling `global.` cross-region with `max_tokens=32000` and no caching will have a completely different experience than one calling `us.` in-region with tight `max_tokens` and warm caches. Skipping characterization leads to wasted investigation.

### Step 2: Ask for a Minimal Reproduction Script

Prepare a **self-contained Python script** that reproduces the issue. This lets anyone run it in a separate account and compare results. Use this template:

```
Create a minimal Python script (boto3 or anthropic SDK) that:

1. Uses a fixed prompt representative of your workload (or equivalent token size)
2. Measures TTFT (if streaming) and E2E latency client-side
3. Runs N iterations (at least 10) with timestamps
4. Outputs per-request metrics (latency, token counts, any errors/throttles)

This helps isolate whether the behavior is account-specific,
region-specific, or general.

If you can't use your actual prompts, a synthetic prompt of the same token
size (e.g. repeated filler text padded to ~10K tokens) works — the model
doesn't need to produce useful output for latency measurement.
```

If you don't have a script yet, generate one based on the invocation profile (use the Reproduce Script workflow from the benchmarking section).

### Step 3: Quick Diagnostic Checklist

Before running any benchmarks, check these common root causes:

#### The `max_tokens` Quota Trap (Most Common Gotcha)
Bedrock reserves quota **at request start** based on `max_tokens`, not actual output. With Claude's 5x burndown on output tokens:
- `max_tokens=32,000` → reserves up to 160,000 tokens of TPM quota per request
- If the model generates only 1,000 tokens → final usage is just 5,000
- But concurrent capacity was blocked by the 160K reservation → phantom throttling

**Check:** What is `max_tokens` set to vs. typical actual output? If `max_tokens` is >5x typical output, this is likely the issue.

#### Throttling Masquerading as Latency
The SDK retries throttled requests silently with backoff. From your application's perspective, this looks like high latency, not throttling.

**Check:**
- CloudWatch `InvocationThrottles` metric for the model — any non-zero = hitting limits
- CloudWatch `EstimatedTPMQuotaUsage` (launched March 2026) — shows actual quota consumption including burndown
- CloudWatch `TimeToFirstToken` (launched March 2026) — server-side TTFT, no client instrumentation needed

#### Region Mismatch
Calling `us-east-1` from an EU-based application will see ~50-100ms+ network penalty on every request. Cross-region inference (`eu.` prefix) or region proximity fixes this.

#### Caching Not Enabled or Not Hitting
For workloads with repeated system prompts or large contexts, enabling prompt caching can reduce TTFT by 50%+. Cache reads don't count toward on-demand TPM quota. But caches expire (5 min default TTL, 1hr available for Claude 4.5+ models) — if request cadence is too slow, every call is a cache miss (write cost, no benefit).

#### Comparing Apples to Oranges
"Anthropic Direct is faster than Bedrock" — but are you comparing:
- Same region? (Direct API is us-east-1; you might be calling `eu.` or `global.` Bedrock)
- Same mode? (Streaming vs non-streaming TTFT are not comparable)
- Same `max_tokens`? (Bedrock quota reservation doesn't apply to Direct API)
- Same time window? (Measured hours apart = different load conditions)

### Step 4: Diagnostic Tools

| Tool | What It Does | When to Use |
|------|-------------|-------------|
| **CloudWatch `TimeToFirstToken`** | Server-side TTFT (ms), no client instrumentation | First check — isolates server vs client/network |
| **CloudWatch `EstimatedTPMQuotaUsage`** | Quota consumption including 5x burndown | When throttling is suspected |
| **CloudWatch `InvocationThrottles`** | Count of throttled requests | When latency is spiky or intermittent |
| **[`awslabs/bedrock-usage-analyzer`](https://github.com/awslabs/bedrock-usage-analyzer)** | HTML report with TPM/RPM timelines, quota lines, throttle events, per-profile breakdown | Deep dive into usage patterns + quota increase justification |
| **CloudTrail `additionalEventData.inferenceRegion`** | Where cross-region requests actually landed | When investigating cross-region routing latency |
| **Service Quotas console** | Actual RPM/TPM limits for the account | Baseline — you may have lower limits than expected (especially newer accounts) |

### Step 5: When to Open an AWS Support Case

If after characterization + diagnostics the issue persists:
- You've right-sized `max_tokens`, no throttling, same-region client, and still see unexpectedly high latency
- Server-side `TimeToFirstToken` CloudWatch metric confirms high TTFT (not client-side)
- Issue is reproducible with the minimal script across multiple time windows

→ Open an AWS Support case and include: account ID, region, model ID, timestamps of affected requests, CloudWatch metric screenshots, and the reproduction script. This gives the support team everything needed to investigate server-side.

---

## Public Benchmark Cross-Reference

When investigating latency issues or setting expectations, public benchmarking sites provide **directional reference points** — but they are NOT diagnostic tools for a specific workload.

### Available Sources

| Source | URL | What It Measures | Update Frequency |
|--------|-----|-----------------|-----------------|
| **Artificial Analysis** | `artificialanalysis.ai/models/claude-sonnet-4-6/providers` | TTFT, OTPS, pricing per provider (incl. Bedrock) | 8x/day (single requests), 2x/day (parallel). Rolling 72hr window |
| **OpenRouter** | `openrouter.ai/anthropic/claude-sonnet-4.6/providers` | Provider list, pricing, routing info | Varies |
| **Artificial Analysis API** | `GET artificialanalysis.ai/api/v2/data/llms/models` (requires API key) | Programmatic access to benchmark data | Same as above |

**To check current public stats**, browse or scrape:
- `https://artificialanalysis.ai/models/claude-sonnet-4-6/providers` — Sonnet 4.6 across providers
- `https://artificialanalysis.ai/models/claude-opus-4-6/providers` — Opus 4.6 across providers
- `https://openrouter.ai/anthropic/claude-sonnet-4.6/providers` — OpenRouter's view
- `https://openrouter.ai/anthropic/claude-opus-4.6/providers` — OpenRouter's view

### Critical Caveats — Always State These

> **Public benchmarks use a specific invocation profile that may not match your workload.**

Specifically:
- **Artificial Analysis** measures with ~10K input tokens at low concurrency, single requests. A workload with 100K-token inputs or high concurrency will see very different TTFT and OTPS.
- **Public stats don't account for your quota utilization.** At 80% TPM utilization you'll see queueing delays invisible to public benchmarks.
- **Cross-region inference profiles route dynamically** — your request may land in a different region than the public benchmark tested.
- **Caching impact is invisible.** Public benchmarks don't test with prompt caching. A workload using caching will see faster TTFT; one not using it on large prompts will see slower.
- **`max_tokens` reservation** is not a factor in Anthropic Direct API tests. Bedrock's quota reservation mechanics mean the same workload can behave differently on Bedrock vs Direct — not because the model is slower, but because of quota accounting.

### How to Use Public Data Responsibly

**DO:**
- Use as a **directional sanity check** — "Is the observed latency wildly different from what public data shows for this model?"
- Compare **your invocation profile** against the public benchmark's profile to understand if differences are expected
- Note the **measurement date** — public stats change week to week

**DON'T:**
- Cite public benchmarks as "proof" that Bedrock is fast/slow for a specific workload
- Compare public single-request TTFT against a concurrent-workload latency measurement
- Assume public Bedrock numbers apply to a specific region, profile type, or quota tier

### Temporal Variability

Latency results are **not static**. They vary across multiple time dimensions:

| Dimension | Impact | What Changes |
|-----------|--------|-------------|
| **Hour of day** | Moderate | Peak US business hours = more contention on us-east-1/us-west-2 on-demand capacity |
| **Day of week** | Low-Moderate | Weekday workloads heavier than weekends |
| **Week to week** | Can be significant | AWS capacity deployments, model version updates, infrastructure changes |
| **Service events** | Can be dramatic | New model launches drive traffic spikes; capacity expansions improve latency |

**Rules for benchmarking over time:**
- Always benchmark across **multiple time windows** (minimum 24h spread, ideally 3-7 days) to capture variability
- Report **when** the measurement was taken (UTC timestamps) — results from last Tuesday don't necessarily apply today
- Report **P50 AND P95/P99** — averages hide temporal spikes
- When comparing to public stats, note their rolling window (e.g. AA uses 72hr) vs your point-in-time measurement
- For intermittent issues, collect **timestamps of affected requests** to correlate with capacity events

---

## Why This Exists

"Model X is slower than Model Y" is not a useful statement without controlled variables. Latency depends on **at least 11 independent variables**, and changing any one of them can flip the result entirely. This bootstrap ensures benchmarks are reproducible, comparable, and defensible.

---

## Variables That Must Be Controlled

Before writing a single line of code, you must nail down every variable below. Each one can independently change the outcome.

### 1. Model ID and Inference Profile Type

The model ID determines not just *which model* but *how it's routed*:

| Prefix | Type | Routing | Example |
|--------|------|---------|---------|
| `anthropic.claude-*` | In-region | Stays in the single region you call | `anthropic.claude-sonnet-4-20250514-v1:0` |
| `us.anthropic.claude-*` | Geographic cross-region (CRIS) | Routes within US regions (us-east-1, us-east-2, us-west-2) | `us.anthropic.claude-sonnet-4-20250514-v1:0` |
| `eu.anthropic.claude-*` | Geographic cross-region (CRIS) | Routes within EU regions | `eu.anthropic.claude-sonnet-4-20250514-v1:0` |
| `global.anthropic.claude-*` | Global cross-region | Routes to any commercial region worldwide | `global.anthropic.claude-sonnet-4-20250514-v1:0` |

**Why it matters:** Cross-region profiles have higher throughput (up to 2x quota) and better availability, but may route to a distant region on any given request. Global profiles offer ~10% cost savings. In-region gives most predictable latency but lowest burst capacity.

**How to check actual routing:** Look at CloudTrail logs for `additionalEventData.inferenceRegion` to see where each request actually landed.

### 2. Input Token Count

Input tokens affect **TTFT** (time to first token) — the model must process the entire input before generating output. The relationship is roughly:
- Small inputs (<1K tokens): Fixed overhead dominates — routing, auth, queue wait
- Medium inputs (1K-10K tokens): Input processing becomes measurable
- Large inputs (10K-200K tokens): Input processing is a significant fraction of total latency

**How to measure accurately:** Use the Bedrock `CountTokens` API to get exact counts, not estimates from tiktoken or similar. Different models tokenize differently.

### 3. Output Token Count

Output tokens dominate total latency. Generation is sequential (autoregressive) — each token depends on all previous ones. The metric **ms/output-token** is the most stable predictor of latency across configurations.

Also critical: the `max_tokens` parameter you set. **Bedrock reserves quota upfront based on `max_tokens`, not actual output.** Setting `max_tokens=32000` when you'll only generate 500 tokens wastes 31,500 tokens of your TPM quota per request — which can cause throttling that *looks like* high latency.

**Rule:** Always set `max_tokens` close to your expected output length, not an arbitrary high value.

**Output token variance:** The model may generate fewer tokens than you need for a meaningful benchmark. Always compare actual output token counts against your target. If the model consistently produces short responses, you may need to craft prompts that explicitly elicit longer output (e.g. "Provide a detailed, step-by-step analysis..." or "List at least 20 examples..."). Without this, you're measuring latency for a shorter workload than your production scenario.

### 4. Thinking/Reasoning Tokens

Extended thinking (reasoning mode) adds an invisible pre-generation phase. Thinking tokens:
- Count against latency (total E2E includes thinking time)
- May not appear clearly in output token counts (depends on API)
- May have a separate `budget_tokens` parameter that caps thinking effort
- Are billed differently (often at a different rate)

**Rule:** If either model in your comparison supports thinking, you must confirm thinking is either ON for both or OFF for both. Otherwise the comparison is meaningless.

### 5. Measurement Timing

LLM inference latency is **not deterministic**. It varies with:
- Time of day (peak hours = more contention on shared on-demand capacity)
- Day of week
- Global demand spikes (new model launches, viral usage)
- Position in the serving queue

**Rules:**
- Compare two models/endpoints in the **same time window** (interleaved or concurrent, never sequential-hours-apart)
- Run at **multiple times** of day if you need representative numbers
- Always report **when** the benchmark was run (UTC timestamp)
- Minimum **10 iterations** per configuration for statistical significance; 20+ preferred

### 6. Latency Metric — Which One?

"Latency" is not one number. Always be explicit about what you're measuring:

| Metric | What It Measures | When It Matters |
|--------|-----------------|-----------------|
| **TTFT** (Time to First Token) | Time from request until first token arrives. Only meaningful in streaming mode. | Interactive/chat UIs where perceived responsiveness matters |
| **E2E** (End-to-End) | Total wall-clock time from request to final token. | Agentic workloads that need the full response to continue, non-streaming APIs, pipeline steps, batch processing. **Most commonly cared about metric.** |
| **P50** (Median) | The midpoint — 50% of requests are faster. | "Typical" experience comparison |
| **P95 / P99** (Tail) | The worst 5% or 1% of requests. | SLA planning, timeout configuration, worst-case UX |
| **OTPS** (Output Tokens Per Second) | Generation throughput after first token. | Comparing raw model speed independent of input processing |

**Report at minimum:** P50, P95, and average for both E2E and TTFT (if streaming).

### 7. Concurrency Level

Single-request sequential benchmarks (one at a time, wait for response, send next) represent **best-case latency** and rarely match production. Under concurrent load:
- Shared on-demand capacity gets contended
- Latency distributions widen, especially at the tail (P95/P99)
- Throttling kicks in at quota limits

**Default to concurrency of 1.** Make this explicit in the benchmark plan. Only suggest higher concurrency testing if concurrency is part of the problem statement (e.g. "latency degrades under load"). Warn that high concurrency can hit account quotas and result in significantly higher cost (more total requests × tokens).

### 8. RPM and TPM Quotas

Bedrock enforces per-model **Requests Per Minute (RPM)** and **Tokens Per Minute (TPM)** service quotas. These vary by:
- Account (new accounts have lower defaults)
- Region
- Model
- Inference profile type (cross-region profiles get up to 2x single-region quota)

**Before benchmarking:** Check your actual limits via the Service Quotas console or `aws service-quotas list-service-quotas`. Two accounts can see very different results purely because of quota differences.

### 9. TPM/RPM Utilization at Measurement Time

The most commonly missed variable. If requests approach or exceed your quota:
- The SDK silently retries throttled requests (exponential backoff)
- From your application's perspective, this looks like very high latency
- It is actually throttling, not model slowness

**How to check:** Monitor CloudWatch metrics `InvocationThrottles` and `EstimatedTPMQuotaUsage` during the benchmark. Also check for `ThrottlingException` in your client logs.

**`max_tokens` trap:** Bedrock reserves quota based on `max_tokens` upfront, not actual output. A request with `max_tokens=32000` that generates 500 tokens temporarily reserves 32K tokens of quota — potentially causing throttling even when your measured TPM usage looks low.

### 10. Client Network Location

Network distance adds latency to every request:

| Client Location | Bedrock Impact | Notes |
|-----------------|---------------|-------|
| Same AWS region as endpoint | Minimal (< 5ms) | Best case for Bedrock |
| Different AWS region | +10-50ms | Cross-region routing adds latency to both |
| Outside AWS (laptop, on-prem) | +20-100ms+ | Internet egress; varies with location and ISP |

**Rule:** Both sides of a comparison must be measured from the same client location. A client in Frankfurt calling `eu.` Bedrock vs. a client in Virginia calling `api.anthropic.com` is not a valid comparison.

**Note on Anthropic Direct API:** The default Anthropic endpoint (`api.anthropic.com`) is a **global endpoint** — it routes to the nearest region. There is also a US-specific endpoint, but most users hit the global one. Keep this in mind when comparing — Bedrock in `us-east-1` vs. Anthropic's global endpoint may route to different infrastructure.

### 11. Streaming vs. Non-Streaming

These are fundamentally different API patterns:

| Mode | API | What You Measure | Connection Pattern |
|------|-----|------------------|--------------------|
| **Non-streaming** | `InvokeModel` / `Converse` | E2E only (full response buffered) | Request → wait → complete response |
| **Streaming** | `InvokeModelWithResponseStream` / `ConverseStream` | E2E + TTFT + OTPS | Request → first token → stream → done |

**Rule:** Never compare streaming TTFT against non-streaming E2E. Always compare like-for-like.

### 12. Service Tier (Nova / Open Source Models Only)

Amazon Nova and select open-source models support tiered inference:

| Tier | Latency | Cost | Use Case |
|------|---------|------|----------|
| **Flex** | Variable, no guarantee | Lowest | Batch, background, non-time-sensitive |
| **Standard** | Balanced (default) | Standard | General production |
| **Priority** | Lowest, most consistent | Highest | Latency-critical real-time |

**Rule:** If comparing Nova or open-source models, confirm which tier was used. Check the `ResolvedServiceTier` CloudWatch dimension for what tier your request actually received.

---

## Benchmark Architecture

### Script Structure

Build a single Python benchmark script with these capabilities:

```
benchmark_bedrock.py
  --models MODEL1,MODEL2,...     # Model keys to test
  --iterations N                 # Iterations per (model × prompt) combination
  --bedrock-region REGION        # AWS region for Bedrock endpoint
  --prompts PROMPT_SET           # Which prompt sizes to use
  --streaming / --no-streaming   # Streaming or non-streaming mode
  --include-direct               # Also test Anthropic Direct API
  --concurrency N                # Parallel requests (default: 1 = sequential)
  --output FILE                  # Save raw results as JSONL
```

### Dependencies

```
pip install anthropic boto3
```

The `anthropic` package provides both `AsyncAnthropic` (direct) and `AsyncAnthropicBedrock` (Bedrock) clients with identical API surfaces.

### Client Setup

```python
from anthropic import AsyncAnthropic, AsyncAnthropicBedrock

# Bedrock — uses IAM credentials from environment/role
bedrock_client = AsyncAnthropicBedrock(aws_region="us-east-1")

# Direct API — requires API key
direct_client = AsyncAnthropic(api_key=api_key)
```

AWS credentials come from the EC2 instance profile (IAM role) — never hardcode. For Direct API, check if the key is already stored in Secrets Manager (`anthropic/api-key`). If not, **ask the user to provide their Anthropic API key** before running any Direct API benchmarks:

```python
import boto3
sm = boto3.client("secretsmanager", region_name="us-east-1")
try:
    api_key = sm.get_secret_value(SecretId="anthropic/api-key")["SecretString"]
except sm.exceptions.ResourceNotFoundException:
    # Key not stored — prompt user to provide it or skip Direct API tests
    print("No Anthropic API key found in Secrets Manager.")
    print("Provide your key with --api-key, or skip Direct API with --no-direct")
```

### Model ID Mapping

Map friendly model names to Bedrock inference profile IDs:

```python
def to_bedrock_model_id(model_key: str, region: str, profile_type: str = "us") -> str:
    """
    profile_type: 'us', 'eu', 'global', or 'regional' (no prefix = in-region only)
    """
    BASE_MODELS = {
        "sonnet-3.7": "anthropic.claude-sonnet-4-5-20250929-v1:0",
        "sonnet-4":   "anthropic.claude-sonnet-4-20250514-v1:0",
        "sonnet-4.6": "anthropic.claude-sonnet-4-6-v1",
        "haiku-4.5":  "anthropic.claude-haiku-4-5-20251001-v1:0",
        "opus-4.6":   "anthropic.claude-opus-4-6-v1",
        # Add new models here as they become available
    }
    base = BASE_MODELS[model_key]
    if profile_type == "regional":
        return base  # in-region, no prefix
    prefix = {"us": "us", "eu": "eu", "global": "global"}.get(profile_type, "us")
    return f"{prefix}.{base}"
```

**Important:** Model IDs change over time. Before running a benchmark, verify the current model IDs via `aws bedrock list-foundation-models` or the Bedrock console. Check `aws bedrock list-inference-profiles` for available cross-region profiles.

### Prompt Design

Design prompts that are representative of the actual workload being benchmarked. Use multiple prompt sizes to understand how latency scales with input:

| Prompt Tier | Input Tokens | Output Tokens | Represents |
|-------------|-------------|---------------|------------|
| Small | ~100-500 | ~10-100 | Classification, routing, yes/no decisions |
| Medium | ~1K-3K | ~200-500 | Summarization, triage, short generation |
| Large | ~10K-15K | ~500-1500 | Code review, document analysis, log analysis |
| XL (optional) | ~40K-180K | ~500+ | Long-context RAG, large document processing |

**Prompt content guidelines:**
- Use realistic, task-representative content — not "write a story" filler
- Keep prompts deterministic across runs (same prompt text every iteration)
- Use separate system and user messages (matching real production patterns)
- Set `max_tokens` close to expected output length (not a high cap)

**For exact token calibration** (XL prompts), use the `CountTokens` API:

```python
br = boto3.client("bedrock-runtime", region_name="us-east-1")
resp = br.count_tokens(
    modelId="anthropic.claude-sonnet-4-20250514-v1:0",
    input={"converse": {"messages": [{"role": "user", "content": [{"text": your_text}]}]}}
)
exact_token_count = resp["inputTokens"]
```

### Measurement

#### Non-Streaming

```python
async def measure_non_streaming(client, model, system, user_msg, max_tokens):
    kwargs = {"model": model, "max_tokens": max_tokens,
              "messages": [{"role": "user", "content": user_msg}]}
    if system:
        kwargs["system"] = system

    start = time.perf_counter()
    response = await client.messages.create(**kwargs)
    e2e_ms = (time.perf_counter() - start) * 1000

    return {
        "e2e_ms": e2e_ms,
        "input_tokens": response.usage.input_tokens,
        "output_tokens": response.usage.output_tokens,
    }
```

#### Streaming (adds TTFT + OTPS)

```python
async def measure_streaming(client, model, system, user_msg, max_tokens):
    kwargs = {"model": model, "max_tokens": max_tokens,
              "messages": [{"role": "user", "content": user_msg}]}
    if system:
        kwargs["system"] = system

    start = time.perf_counter()
    ttft_ms = None

    async with client.messages.stream(**kwargs) as stream:
        async for _text in stream.text_stream:
            if ttft_ms is None:
                ttft_ms = (time.perf_counter() - start) * 1000

    e2e_ms = (time.perf_counter() - start) * 1000
    final = await stream.get_final_message()

    return {
        "e2e_ms": e2e_ms,
        "ttft_ms": ttft_ms,
        "input_tokens": final.usage.input_tokens,
        "output_tokens": final.usage.output_tokens,
        "otps": final.usage.output_tokens / (e2e_ms / 1000) if e2e_ms > 0 else 0,
    }
```

#### With Prompt Caching

For large-context benchmarks, separate cold (cache write) from warm (cache read) iterations:

```python
messages = [{
    "role": "user",
    "content": [
        {"type": "text", "text": large_context, "cache_control": {"type": "ephemeral"}},
        {"type": "text", "text": question},
    ],
}]
# Iteration 1 = cold (cache write), iterations 2+ = warm (cache read)
# Report cold and warm latency separately — cache hits dramatically change the numbers
```

Check cache usage in the response:
```python
cache_write = getattr(usage, "cache_creation_input_tokens", 0) or 0
cache_read = getattr(usage, "cache_read_input_tokens", 0) or 0
```

### Statistics

Report these for each (model × prompt × backend) combination:

```python
import statistics

def compute_stats(latencies: list[float]) -> dict:
    return {
        "n": len(latencies),
        "avg": statistics.mean(latencies),
        "p50": percentile(latencies, 50),
        "p95": percentile(latencies, 95),
        "p99": percentile(latencies, 99),
        "min": min(latencies),
        "max": max(latencies),
        "stdev": statistics.stdev(latencies) if len(latencies) > 1 else 0,
    }
```

### Output Format

Save every individual call as a JSONL line (for reanalysis later):

```jsonl
{"ts":"2026-04-15T12:00:00Z","backend":"bedrock-us","model":"us.anthropic.claude-sonnet-4-6-v1","prompt":"code_review_10k","iteration":1,"e2e_ms":8234,"ttft_ms":412,"input_tokens":10411,"output_tokens":523,"cache_write":0,"cache_read":0}
```

Generate a markdown report summarizing:
1. **Test configuration** — all variables listed above
2. **Per-model results** — E2E stats (avg, P50, P95), TTFT stats, OTPS, ms/output-token
3. **Cross-model comparison table** — side by side for easy reading
4. **Delta analysis** — percentage differences between models/backends
5. **Cache analysis** (if applicable) — cold vs warm, cache hit ratio validation
6. **Cost per call** — using current Bedrock pricing

---

## Running the Benchmark

### Pre-Flight Checklist

Before running:

1. **Verify model access:** `aws bedrock list-foundation-models --query "modelSummaries[?modelId=='anthropic.claude-sonnet-4-6-v1'].modelId"` — confirms the model is available in your region
2. **Check quotas:** `aws service-quotas list-service-quotas --service-code bedrock --query "Quotas[?contains(QuotaName, 'Sonnet')]"` — know your RPM and TPM limits
3. **Verify IAM permissions:** Your role needs `bedrock:InvokeModel`, `bedrock:InvokeModelWithResponseStream`, and optionally `bedrock:CountTokens`
4. **Install dependencies:** `pip install anthropic boto3`
5. **Estimate cost:** Calculate estimated token usage × pricing before running. Print the estimate and require confirmation before proceeding
6. **Check disk space:** Raw results can be large for XL prompts. Ensure space for JSONL output

### Execution Pattern

```bash
# Basic: compare two models on Bedrock, 10 iterations, us-east-1
python benchmark_bedrock.py \
  --models sonnet-3.7,sonnet-4.6 \
  --iterations 10 \
  --bedrock-region us-east-1 \
  --prompts all \
  --no-streaming \
  --output results/run_$(date +%Y%m%d_%H%M%S).jsonl

# With streaming metrics
python benchmark_bedrock.py \
  --models sonnet-4.6 \
  --iterations 20 \
  --bedrock-region us-east-1 \
  --streaming \
  --output results/streaming_run.jsonl

# Cross-region comparison
python benchmark_bedrock.py \
  --models sonnet-4.6 \
  --bedrock-region us-east-1 \
  --iterations 10 \
  --output results/use1.jsonl
python benchmark_bedrock.py \
  --models sonnet-4.6 \
  --bedrock-region us-west-2 \
  --iterations 10 \
  --output results/usw2.jsonl

# Bedrock vs Direct API (requires Anthropic API key in Secrets Manager)
python benchmark_bedrock.py \
  --models sonnet-4.6 \
  --iterations 10 \
  --include-direct \
  --api-key-secret anthropic/api-key \
  --output results/bedrock_vs_direct.jsonl
```

### Rate Limit Handling

- **Bedrock on-demand:** Generally generous quotas for Sonnet/Haiku; add 1-2 second sleep between iterations if you see 429s
- **Anthropic Direct API:** More aggressive rate limits (especially TPM on cache writes). Implement dynamic sleep based on token usage:
  ```python
  # After each call, sleep proportional to tokens consumed relative to your TPM limit
  sleep_seconds = (tokens_consumed / tpm_limit) * 60 * 1.2  # 20% safety margin
  ```
- **Always implement retry with exponential backoff** for 429 errors (start at 2s, max 120s, 5 retries)
- **Log throttling events** — they're data, not just errors. If a benchmark shows high throttle rates, the results are measuring your quota, not the model

### Cost Awareness

Print estimated cost before starting and require explicit confirmation:

```
Estimated cost: ~$4.52 (120 calls × 3 models × ~10K input + ~500 output tokens)
Press Enter to start, Ctrl+C to abort...
```

Use current Bedrock pricing (check https://aws.amazon.com/bedrock/pricing/):
- Input tokens × price per 1M input tokens
- Output tokens × price per 1M output tokens
- Cache write tokens × write price (if using caching)
- Cache read tokens × read price (if using caching)

---

## Report Template

The benchmark should auto-generate a markdown report. Structure:

```markdown
# Bedrock Model Latency Benchmark
**Date:** YYYY-MM-DD HH:MM UTC
**Region:** us-east-1
**Client:** EC2 in us-east-1 (same-region, minimal network)
**Mode:** Non-streaming | Streaming
**Iterations:** N per (model × prompt)
**Thinking:** Off | On (budget: N tokens)

## Models Tested
| Model | Bedrock Model ID | Profile Type |
|-------|-----------------|--------------|
| ... | ... | us / eu / global / regional |

## Prompts
| Name | Input Tokens | Max Output | Description |
|------|-------------|-----------|-------------|
| ... | ... | ... | ... |

## Results — Model A vs Model B

### E2E Latency
| Prompt | Model A Avg | Model A P50 | Model A P95 | Model B Avg | Model B P50 | Model B P95 | Delta % (P50) |
|--------|------------|------------|------------|------------|------------|------------|--------------|
| ... | ... | ... | ... | ... | ... | ... | ... |

### TTFT (streaming only)
(same format)

### Output Throughput (tokens/sec)
(same format)

### ms per Output Token
(most stable comparison metric)

## Key Findings
1. ...
2. ...

## Caveats
- Measured at [time], single-threaded, on-demand quota
- ...
```

---

## Common Pitfalls

1. **Comparing different model ID prefixes** — `us.` vs `global.` vs bare model IDs have different routing and quotas. Always compare same prefix.

2. **Not warming up** — The first 1-2 requests after a cold start may be slower (model loading, connection establishment). Run 2-3 warmup iterations and exclude them from stats.

3. **`max_tokens` set too high** — Wastes quota, causes phantom throttling. Match it to expected output.

4. **Measuring from outside AWS** — Internet variability swamps the actual model latency difference. Benchmark from an EC2 instance in the same region.

5. **Sequential model testing** — Running all Model A iterations, then all Model B iterations means they're measured at different times. Interleave: A1, B1, A2, B2, ... to control for time-varying load.

6. **Ignoring output token count variation** — Models generate different amounts of output for the same prompt. Always report ms/output-token alongside raw E2E.

7. **Caching confounds** — If prompt caching is enabled, iteration 1 (cache write) is always slower. Report cold and warm separately, or exclude iteration 1.

8. **Assuming results generalize** — A benchmark with 500-token inputs tells you nothing about 50K-token performance. Latency scales non-linearly with input size. Test at your actual payload sizes.

9. **Silent retries masking throttling** — The boto3 and `anthropic` SDKs automatically retry throttled requests (429s) with exponential backoff. From your application's perspective, this looks like high latency, not throttling. If you see unexpectedly high or variable E2E times, check CloudWatch `InvocationThrottles` for the model during the measurement window. Any non-zero count means you were hitting quota limits, and your "latency" numbers actually include retry wait time.

10. **Not checking the CloudWatch Bedrock dashboard** — Before and during benchmarks, check the [Amazon Bedrock automatic CloudWatch dashboard](https://aws.amazon.com/blogs/machine-learning/improve-visibility-into-amazon-bedrock-usage-and-performance-with-amazon-cloudwatch/). Navigate to **CloudWatch → Dashboards → Automatic dashboards → Bedrock**. Compare your RPM and TPM metrics at the time of high latency against your account quotas. This is the fastest way to confirm whether observed latency is genuine model performance or quota-induced queueing.

---

## AGENTS.md Snippet (token-optimized — add this)

```markdown
## Bedrock Benchmarking

### Variables to control (ALL must be reported)
- Model ID + inference profile type (regional/us/eu/global)
- Input & output token counts (use CountTokens API for exact)
- Thinking tokens on/off and budget
- Measurement timestamp (UTC)
- Streaming vs non-streaming
- Concurrency level
- Client location (same-region EC2 = baseline)
- RPM/TPM quota limits for the account+model
- Actual TPM/RPM utilization during measurement

### Methodology
- Min 10 iterations (20+ preferred); 2-3 warmup iterations excluded
- Interleave models (A1,B1,A2,B2...) — never sequential blocks
- Report: avg, P50, P95, ms/output-token
- Save raw JSONL per-call for reanalysis
- Set max_tokens close to expected output (not arbitrary high)
- Check InvocationThrottles during benchmark — throttling looks like latency
- Separate cold (cache write) from warm (cache read) if caching enabled
- Print cost estimate + require confirmation before running

### Quick run
```bash
python benchmark_bedrock.py --models MODEL1,MODEL2 --iterations 10 --bedrock-region us-east-1 --output results/run.jsonl
```
```

---

## Assumptions

- **On-demand inference only.** Batch inference and Provisioned Throughput have fundamentally different latency profiles and should not be compared with on-demand.
- **No Guardrails or post-processing** attached to the model. Bedrock Guardrails add measurable latency. If your production setup uses Guardrails, benchmark with them enabled — but know they're adding overhead.
- **Python `anthropic` SDK.** If you're using a different SDK (boto3 raw, LangChain, etc.), SDK overhead may differ. The `anthropic` SDK is the thinnest wrapper and closest to raw API performance.
