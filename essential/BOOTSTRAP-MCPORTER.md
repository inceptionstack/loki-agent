# BOOTSTRAP-MCPORTER.md — MCPorter Setup

> **Run this once on first boot.** If `memory/.bootstrapped-mcporter` exists, skip — you've already done this.

## What Is MCPorter?

[MCPorter](https://github.com/steipete/mcporter) is a CLI tool for calling MCP (Model Context Protocol) servers directly — no IDE integration needed. It lets you list, configure, authenticate, and call MCP server tools from the command line.

You have it installed. Confirm:

```bash
mcporter --version
```

## 1. Check Your Config

MCPorter reads server definitions from a JSON config file. Check if one exists:

```bash
ls ~/.openclaw/workspace/config/mcporter.json
```

If it exists, list available servers:

```bash
mcporter list --config ~/.openclaw/workspace/config/mcporter.json
```

If it doesn't exist, create a minimal config:

```bash
mkdir -p ~/.openclaw/workspace/config
cat > ~/.openclaw/workspace/config/mcporter.json << 'EOF'
{
  "mcpServers": {}
}
EOF
```

You'll add servers to this as needed.

## 2. How To Use MCPorter

**List tools on a server:**
```bash
mcporter list <server-name> --config ~/.openclaw/workspace/config/mcporter.json
```

**Call a tool:**
```bash
mcporter call <server-name>.<tool-name> key=value key2=value2 --config ~/.openclaw/workspace/config/mcporter.json
```

**Examples:**
```bash
# List all tools on a server
mcporter list aws-mcp-server --config ~/.openclaw/workspace/config/mcporter.json

# Call a specific tool
mcporter call aws-mcp-server.aws___call_aws cli_command="aws s3 ls" --config ~/.openclaw/workspace/config/mcporter.json
```

## 3. Adding MCP Servers

To add a new server, edit `~/.openclaw/workspace/config/mcporter.json` and add an entry under `mcpServers`:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "npx",
      "args": ["-y", "@some/mcp-server"]
    }
  }
}
```

Servers can be `command`-based (stdio) or `url`-based (HTTP/SSE). Check the MCP server's docs for the right config.

## 4. Tips

- MCPorter starts MCP servers on-demand per call — no persistent daemon needed
- Array/object params use JSON syntax: `topics='["general"]'`
- Use `mcporter list <server>` to discover available tools and their parameter schemas before calling
- If a server fails to start, check the command/args and ensure dependencies are installed
- There's also an `mcporter` OpenClaw skill with deeper usage docs — check `skills/mcporter/SKILL.md` if installed

## 5. Document What You Set Up

After configuring servers, update `TOOLS.md` with:
- Which MCP servers are available
- What each one does
- Example commands for common tasks

This is your cheat sheet — future-you will thank present-you.

## 6. Finish

After completing all steps:
```bash
mkdir -p memory && echo "MCPorter bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-mcporter
```

Report to the operator what MCP servers are configured and available.
