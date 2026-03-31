# Hermes Agent — configured to use bedrockify (Bedrock proxy)
model:
  default: "${MODEL}"
  provider: "custom"
  base_url: "http://127.0.0.1:${BEDROCKIFY_PORT}/v1"

terminal:
  backend: "local"
  cwd: "."
  timeout: 180

agent:
  max_turns: 60
  reasoning_effort: "medium"

compression:
  enabled: true
  threshold: 0.50
  summary_model: "${MODEL}"

display:
  streaming: true
  tool_progress: all
