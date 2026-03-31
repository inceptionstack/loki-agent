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

## Pi-Specific Configuration

Pi has no built-in browser automation. There is no native Playwright integration.

As a potential workaround: if Pi gains MCP support via a future extension, the Playwright MCP server could be loaded. For now, browser tasks are not natively supported in Pi — use OpenClaw or Hermes for browser automation needs.

The Chromium binary at `/home/ec2-user/.cache/ms-playwright/` is available on the instance regardless.

## IronClaw-Specific Configuration

IronClaw has no documented native browser automation support. The Playwright Chromium binary is pre-installed on the instance and available for manual invocation via IronClaw's `shell` tool:

```bash
# IronClaw can invoke Playwright via its shell tool
npx playwright chromium --headless https://example.com
```

For richer browser automation, consider adding the Playwright MCP server to IronClaw's MCP config (see `BOOTSTRAP-MCPORTER.md` for the server definition). This gives IronClaw structured browser control via MCP tools.
