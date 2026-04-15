[Unit]
Description=OpenClaw Gateway (v${OC_VERSION})
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${NODE_BIN} ${OC_MAIN} gateway --port ${GW_PORT}
Restart=always
RestartSec=5
KillMode=process
Environment="HOME=${USER_HOME}"
Environment="PATH=${USER_HOME}/.local/bin:${USER_HOME}/.local/share/mise/installs/node/current/bin:${NODE_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin"
Environment=AWS_PROFILE=default
Environment=AWS_REGION=${AWS_DEFAULT_REGION}
Environment=AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}
Environment=OPENCLAW_GATEWAY_PORT=${GW_PORT}
Environment=OPENCLAW_GATEWAY_TOKEN=${GW_TOKEN}
Environment=OPENCLAW_SYSTEMD_UNIT=openclaw-gateway.service
Environment=OPENCLAW_SERVICE_MARKER=openclaw
Environment=OPENCLAW_SERVICE_KIND=gateway
Environment=OPENCLAW_SERVICE_VERSION=${OC_VERSION}

[Install]
WantedBy=default.target
