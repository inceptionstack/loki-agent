## Playwright — Browser Automation

> **Applies to:** All agents (with agent-specific sections below)

Playwright provides headless browser automation for web scraping, testing, and interaction. The Chromium binary is pre-installed on the instance.

### Verify Chromium is installed

```bash
ls /home/ec2-user/.cache/ms-playwright/chromium-*/chrome-linux/chrome
```

If missing, install it:

```bash
npx playwright install chromium
```

---

## OpenClaw-Specific Configuration

OpenClaw uses Playwright via MCPorter as an MCP server. Confirm it's working:

```bash
mcporter list
```

You should see `playwright` (22 tools, healthy). If it's missing, add it to `~/.openclaw/workspace/config/mcporter.json` under `mcpServers`:

```json
"playwright": {
  "command": "npx @playwright/mcp --headless --executable-path /home/ec2-user/.cache/ms-playwright/chromium-1208/chrome-linux/chrome"
}
```

Use it via mcporter: `mcporter call playwright.browser_navigate url="https://example.com"`, then `playwright.browser_snapshot` to capture the page, `playwright.browser_click` / `playwright.browser_type` to interact, and `playwright.browser_screenshot` to capture visuals. Always run headless (no display on this server).

OpenClaw also has a built-in `browser` tool that can use Playwright directly — check if it's available before setting up the MCPorter route.

## Hermes-Specific Configuration

Hermes uses Playwright under the covers for browser automation. Verify it's working:

```bash
# Check Playwright is available
npx playwright --version

# Test headless browser launch
npx playwright open --headless https://example.com 2>/dev/null && echo "Playwright OK"
```

If the Chromium binary is present (checked above), Hermes can use browser automation out of the box. No additional configuration needed — Hermes invokes Playwright directly as part of its agent toolchain.
