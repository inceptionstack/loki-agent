## Playwright via MCPorter

You have Playwright available as an MCP server via mcporter. Confirm it's working by running mcporter list — you should see playwright (22 tools, healthy). If it's missing, add it to ~/.openclaw/workspace/config/mcporter.json under mcpServers:

"playwright": {
 "command": "npx @playwright/mcp --headless --executable-path /home/ec2-user/.cache/ms-playwright/chromium-1208/chrome-linux/chrome"
}

The Chromium binary is pre-installed at that path. To use it, call tools via mcporter call playwright.<tool_name> — e.g. mcporter call playwright.browser_navigate url="https://example.com", then playwright.browser_snapshot to capture the page, playwright.browser_click / playwright.browser_type to interact, and playwright.browser_screenshot to capture visuals. Always run headless (no display on this server). No separate install needed — npx @playwright/mcp pulls the MCP server on first use.
