# REFERENCE ONLY — not used by install.sh (bedrockify install-daemon creates its own unit).
# Kept for documentation and manual installs.
[Unit]
Description=Bedrockify — OpenAI-compatible Bedrock Proxy
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/bedrockify serve \
  --region   ${BEDROCKIFY_REGION} \
  --model    ${BEDROCKIFY_MODEL} \
  --embed-model ${BEDROCKIFY_EMBED_MODEL} \
  --port     ${BEDROCKIFY_PORT}
Restart=always
RestartSec=5
KillMode=process
Environment="HOME=/home/ec2-user"
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
Environment=AWS_DEFAULT_REGION=${BEDROCKIFY_REGION}
Environment=BEDROCKIFY_PORT=${BEDROCKIFY_PORT}
Environment=BEDROCKIFY_REGION=${BEDROCKIFY_REGION}
Environment=BEDROCKIFY_MODEL=${BEDROCKIFY_MODEL}
Environment=BEDROCKIFY_EMBED_MODEL=${BEDROCKIFY_EMBED_MODEL}

[Install]
WantedBy=multi-user.target
