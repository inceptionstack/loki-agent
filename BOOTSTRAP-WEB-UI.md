# BOOTSTRAP-WEB-UI.md — Expose OpenClaw Control UI via CloudFront + Cognito

> **Target audience:** You are an OpenClaw agent implementing this for your human. Follow every step. At the end, you MUST guide your human through manual browser steps (device pairing + gateway token). Present the full plan to the user and get approval before making any infrastructure changes.

## What This Does

Exposes the OpenClaw Gateway's built-in Control UI (Vite + Lit SPA) through a CloudFront distribution, secured by Cognito login. The gateway stays on loopback — a Node.js proxy on the same EC2 handles Cognito JWT validation and proxies HTTP + WebSocket to the gateway.

## Architecture

```
Browser (HTTPS)
    ↓
CloudFront (TLS termination, no caching, dedicated distribution)
    ↓
ALB (HTTP, port 80)
    ↓
Node.js Proxy (EC2, port 3102)
    ↓  validates Cognito JWT cookie
    ↓  proxies HTTP + WebSocket
Gateway (127.0.0.1:18789)
```

**Three auth layers:**
1. ALB security group → only CloudFront IPs allowed inbound
2. Proxy → Cognito JWT validation via JWKS
3. Gateway → its own bearer token (user pastes once in browser)

## Prerequisites

- EC2 instance running OpenClaw with gateway on loopback (`gateway.bind: "loopback"`)
- AWS Cognito User Pool with a Hosted UI domain configured
- Node.js 20+ on the EC2 instance
- The instance must be in a VPC with at least 2 subnets in different AZs (for ALB)

## Before You Start — Present This Plan to the User

**Before creating any infrastructure, show the user what you're about to do and ask for approval.** Something like:

> I'm going to set up the OpenClaw Control UI accessible via CloudFront + Cognito. Here's the plan:
>
> **Infrastructure I'll create:**
> - ALB (Application Load Balancer) with a security group locked to CloudFront IPs
> - Target group pointing to a proxy on this EC2 (port 3102)
> - CloudFront distribution (dedicated, HTTPS, no caching)
> - Cognito app client with callback URL for the new CloudFront domain
> - Node.js proxy as a systemd service on this instance
> - Gateway config update (basePath, allowedOrigins)
>
> **What you'll need to do manually after (in your browser):**
> 1. Open the CloudFront URL and log in with your Cognito credentials
> 2. Paste the gateway token once (I'll give it to you)
> 3. Approve device pairing once (I'll run the approval command)
>
> **Estimated time:** ~5 minutes for infra, ~5 minutes for CloudFront to deploy
>
> Shall I proceed?

Wait for the user to confirm before continuing.

---

## Step 1: Gather Information

Collect these values — you'll need them throughout:

```bash
# Your EC2 instance ID
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/meta-data/instance-id)

# VPC and subnets
VPC_ID=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region us-east-1 --query 'Reservations[0].Instances[0].VpcId' --output text)

# Get subnets in at least 2 AZs
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --region us-east-1 --query 'Subnets[*].[SubnetId,AvailabilityZone]' --output text)

# EC2 security group
EC2_SG=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region us-east-1 --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)

# Cognito pool ID (check your OpenClaw config or ask the user)
COGNITO_POOL_ID="..."       # e.g. us-east-1_AbCdEfGhI
COGNITO_DOMAIN="..."        # e.g. my-app.auth.us-east-1.amazoncognito.com

# Gateway token (from OpenClaw config)
GATEWAY_TOKEN=$(grep -o '"token": *"[^"]*"' ~/.openclaw/openclaw.json | head -1 | sed 's/"token": *"//;s/"//')
# Or from Secrets Manager if stored there
```

## Step 2: Create the Proxy

### Install dependencies

```bash
mkdir -p /tmp/openclaw-ui-proxy && cd /tmp/openclaw-ui-proxy

cat > package.json << 'EOF'
{
  "name": "openclaw-ui-proxy",
  "version": "1.0.0",
  "type": "module",
  "dependencies": {
    "http-proxy": "^1.18.1",
    "jose": "^6.0.0"
  }
}
EOF

npm install
```

### Proxy source (`server.mjs`)

Create this file. The proxy handles:
- Cognito OAuth2 code flow (redirect to Hosted UI → exchange code → set httpOnly cookie)
- JWT verification on every HTTP request and WebSocket upgrade using JWKS
- HTTP + WebSocket passthrough to the gateway on localhost

```javascript
import http from 'node:http';
import httpProxy from 'http-proxy';
import * as jose from 'jose';

// ── Config (all from environment) ────────────────────────────────────────────
const PORT = parseInt(process.env.PORT || '3102', 10);
const COGNITO_REGION = process.env.COGNITO_REGION || 'us-east-1';
const COGNITO_POOL_ID = process.env.COGNITO_POOL_ID;
const COGNITO_DOMAIN = process.env.COGNITO_DOMAIN;
const COGNITO_CLIENT_ID = process.env.COGNITO_CLIENT_ID;
const GATEWAY_TARGET = process.env.GATEWAY_TARGET || 'http://127.0.0.1:18789';

const COGNITO_ISSUER = `https://cognito-idp.${COGNITO_REGION}.amazonaws.com/${COGNITO_POOL_ID}`;
const JWKS_URL = `${COGNITO_ISSUER}/.well-known/jwks.json`;

// ── JWKS / JWT Verification ──────────────────────────────────────────────────
const JWKS = jose.createRemoteJWKSet(new URL(JWKS_URL));

async function verifyJwt(token) {
  const { payload } = await jose.jwtVerify(token, JWKS, { issuer: COGNITO_ISSUER });
  return payload;
}

// ── Helpers ──────────────────────────────────────────────────────────────────
function parseCookies(cookieHeader) {
  const cookies = {};
  if (!cookieHeader) return cookies;
  cookieHeader.split(';').forEach((c) => {
    const [name, ...rest] = c.trim().split('=');
    if (name) cookies[name] = rest.join('=');
  });
  return cookies;
}

function getRedirectUri(req) {
  const host = req.headers['x-forwarded-host'] || req.headers.host;
  // Always https — CloudFront terminates TLS, ALB forwards as http
  return `https://${host}/callback`;
}

async function checkAuth(req) {
  const cookies = parseCookies(req.headers.cookie);
  const idToken = cookies['oc_id_token'];
  if (!idToken) return false;
  try {
    await verifyJwt(idToken);
    return true;
  } catch {
    return false;
  }
}

// ── Proxy ────────────────────────────────────────────────────────────────────
const proxy = httpProxy.createProxyServer({
  target: GATEWAY_TARGET,
  ws: true,
  changeOrigin: true,
  secure: false,
});

proxy.on('error', (err, req, res) => {
  console.error('[proxy] error:', err.message);
  if (res?.writeHead) {
    res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Gateway proxy error: ' + err.message }));
  }
});

// ── HTTP Server ──────────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  // Health check (no auth — ALB health checks hit this)
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ status: 'ok', ts: Date.now() }));
  }

  // Login redirect → Cognito Hosted UI
  if (req.url === '/login') {
    const redirectUri = getRedirectUri(req);
    const loginUrl = `https://${COGNITO_DOMAIN}/login?response_type=code&client_id=${COGNITO_CLIENT_ID}&redirect_uri=${encodeURIComponent(redirectUri)}&scope=openid+email+profile`;
    res.writeHead(302, { Location: loginUrl });
    return res.end();
  }

  // OAuth callback — exchange code for tokens, set cookie
  if (req.url.startsWith('/callback')) {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const code = url.searchParams.get('code');
    if (!code) {
      res.writeHead(302, { Location: '/login' });
      return res.end();
    }

    const redirectUri = getRedirectUri(req);
    try {
      const tokenRes = await fetch(`https://${COGNITO_DOMAIN}/oauth2/token`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          grant_type: 'authorization_code',
          client_id: COGNITO_CLIENT_ID,
          code,
          redirect_uri: redirectUri,
        }).toString(),
      });

      if (!tokenRes.ok) {
        console.error('[callback] token exchange failed:', await tokenRes.text());
        res.writeHead(302, { Location: '/login' });
        return res.end();
      }

      const tokens = await tokenRes.json();
      const maxAge = tokens.expires_in || 3600;
      res.writeHead(302, {
        Location: '/',
        'Set-Cookie': `oc_id_token=${tokens.id_token}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAge}`,
      });
      return res.end();
    } catch (err) {
      console.error('[callback] error:', err.message);
      res.writeHead(302, { Location: '/login' });
      return res.end();
    }
  }

  // Logout
  if (req.url === '/logout') {
    res.writeHead(302, {
      Location: '/login',
      'Set-Cookie': 'oc_id_token=; Path=/; HttpOnly; Secure; Max-Age=0',
    });
    return res.end();
  }

  // All other paths — check auth, then proxy to gateway
  const authed = await checkAuth(req);
  if (!authed) {
    res.writeHead(302, { Location: '/login' });
    return res.end();
  }

  proxy.web(req, res);
});

// ── WebSocket Upgrade ────────────────────────────────────────────────────────
server.on('upgrade', async (req, socket, head) => {
  const authed = await checkAuth(req);
  if (!authed) {
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    socket.destroy();
    return;
  }
  proxy.ws(req, socket, head);
});

// ── Start ────────────────────────────────────────────────────────────────────
server.listen(PORT, '0.0.0.0', () => {
  console.log(`[openclaw-ui-proxy] listening on 0.0.0.0:${PORT}`);
  console.log(`[openclaw-ui-proxy] proxying to ${GATEWAY_TARGET}`);
});
```

### Install as systemd service

```bash
sudo mkdir -p /opt/openclaw-ui-proxy
sudo cp server.mjs package.json /opt/openclaw-ui-proxy/
sudo cp -r node_modules /opt/openclaw-ui-proxy/

sudo tee /etc/systemd/system/openclaw-ui-proxy.service > /dev/null << 'EOF'
[Unit]
Description=OpenClaw Control UI Proxy
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/openclaw-ui-proxy
ExecStart=/usr/bin/node server.mjs
Restart=always
RestartSec=5
Environment=PORT=3102
Environment=COGNITO_REGION=us-east-1
Environment=COGNITO_POOL_ID=REPLACE_ME
Environment=COGNITO_DOMAIN=REPLACE_ME
Environment=COGNITO_CLIENT_ID=REPLACE_ME
Environment=GATEWAY_TARGET=http://127.0.0.1:18789

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now openclaw-ui-proxy
```

Verify: `curl -s http://localhost:3102/health` should return `{"status":"ok",...}`.

> **Note on Node.js path:** Adjust the `ExecStart` path to wherever `node` is installed on the system (e.g. `/usr/bin/node`, `/home/ubuntu/.local/share/mise/installs/node/X.Y.Z/bin/node`, etc.).

## Step 3: Create ALB + Security Group

```bash
# Create ALB security group — only CloudFront IPs allowed inbound
ALB_SG=$(aws ec2 create-security-group \
  --group-name openclaw-ui-alb-sg \
  --description "OpenClaw UI ALB - CloudFront only" \
  --vpc-id "$VPC_ID" \
  --region us-east-1 \
  --query 'GroupId' --output text)

# Get CloudFront managed prefix list
CF_PREFIX_LIST=$(aws ec2 describe-managed-prefix-lists \
  --filters "Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing" \
  --region us-east-1 \
  --query 'PrefixLists[0].PrefixListId' --output text)

# Allow inbound HTTP from CloudFront only
aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":80,\"ToPort\":80,\"PrefixListIds\":[{\"PrefixListId\":\"$CF_PREFIX_LIST\"}]}]" \
  --region us-east-1

# Pick 2 subnets in different AZs for the ALB
SUBNET_1="REPLACE_ME"  # Subnet in AZ-a
SUBNET_2="REPLACE_ME"  # Subnet in AZ-b (or AZ-c, etc.)

# Create ALB
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name openclaw-ui-alb \
  --subnets "$SUBNET_1" "$SUBNET_2" \
  --security-groups "$ALB_SG" \
  --scheme internet-facing \
  --type application \
  --region us-east-1 \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --region us-east-1 \
  --query 'LoadBalancers[0].DNSName' --output text)
```

### Create target group + listener

```bash
# Target group
TG_ARN=$(aws elbv2 create-target-group \
  --name openclaw-ui-tg \
  --protocol HTTP \
  --port 3102 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --region us-east-1 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Register EC2 instance
aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets Id="$INSTANCE_ID",Port=3102 \
  --region us-east-1

# Create listener — forwards all traffic to the proxy
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-action "[{\"Type\":\"forward\",\"TargetGroupArn\":\"$TG_ARN\"}]" \
  --region us-east-1 \
  --query 'Listeners[0].ListenerArn' --output text)
```

### Allow ALB → EC2

Add an inbound rule to the EC2 security group so the ALB can reach port 3102:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$EC2_SG" \
  --protocol tcp \
  --port 3102 \
  --source-group "$ALB_SG" \
  --region us-east-1
```

Wait for target to become healthy (~30-60s):

```bash
# Poll until healthy
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --region us-east-1 \
  --query 'TargetHealthDescriptions[0].TargetHealth.State'
```

## Step 4: Create CloudFront Distribution

Key settings:
- **No caching** — managed `CachingDisabled` policy
- **AllViewer origin request policy** — forwards all cookies, headers, query strings (needed for auth cookies + WebSocket upgrade)
- **All HTTP methods** — needed for WebSocket and API calls
- **Origin read timeout 60s** — the gateway can take time on first response

```bash
cat > /tmp/cf-config.json << CFJSON
{
  "CallerReference": "openclaw-ui-$(date +%s)",
  "Comment": "OpenClaw Control UI",
  "Enabled": true,
  "DefaultCacheBehavior": {
    "TargetOriginId": "alb-openclaw-ui",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 7,
      "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] }
    },
    "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
    "OriginRequestPolicyId": "216adef6-5c7f-47e4-b989-5492eafa07d3",
    "Compress": true
  },
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "alb-openclaw-ui",
        "DomainName": "$ALB_DNS",
        "CustomOriginConfig": {
          "HTTPPort": 80,
          "HTTPSPort": 443,
          "OriginProtocolPolicy": "http-only",
          "OriginReadTimeout": 60,
          "OriginKeepaliveTimeout": 5
        }
      }
    ]
  },
  "PriceClass": "PriceClass_100"
}
CFJSON

CF_RESULT=$(aws cloudfront create-distribution \
  --distribution-config file:///tmp/cf-config.json \
  --region us-east-1 --output json)

CF_ID=$(echo "$CF_RESULT" | jq -r '.Distribution.Id')
CF_DOMAIN=$(echo "$CF_RESULT" | jq -r '.Distribution.DomainName')
```

Wait for deployment (~2-5 minutes):

```bash
aws cloudfront wait distribution-deployed --id "$CF_ID"
```

## Step 5: Configure Cognito App Client

Create (or update) a Cognito app client with the CloudFront callback URL:

```bash
CLIENT_ID=$(aws cognito-idp create-user-pool-client \
  --user-pool-id "$COGNITO_POOL_ID" \
  --client-name "openclaw-ui" \
  --no-generate-secret \
  --supported-identity-providers COGNITO \
  --callback-urls "https://$CF_DOMAIN/callback" \
  --logout-urls "https://$CF_DOMAIN/" \
  --allowed-o-auth-flows code \
  --allowed-o-auth-scopes openid email profile \
  --allowed-o-auth-flows-user-pool-client \
  --explicit-auth-flows ALLOW_USER_SRP_AUTH ALLOW_REFRESH_TOKEN_AUTH \
  --region us-east-1 \
  --query 'UserPoolClient.ClientId' --output text)
```

If updating an existing client instead:

```bash
aws cognito-idp update-user-pool-client \
  --user-pool-id "$COGNITO_POOL_ID" \
  --client-id "$EXISTING_CLIENT_ID" \
  --callback-urls "https://$CF_DOMAIN/callback" \
  --logout-urls "https://$CF_DOMAIN/" \
  --region us-east-1
```

**Now update the systemd service** with the real Cognito values and restart:

```bash
# Edit the service environment variables with real values
sudo sed -i "s/COGNITO_POOL_ID=REPLACE_ME/COGNITO_POOL_ID=$COGNITO_POOL_ID/" /etc/systemd/system/openclaw-ui-proxy.service
sudo sed -i "s/COGNITO_DOMAIN=REPLACE_ME/COGNITO_DOMAIN=$COGNITO_DOMAIN/" /etc/systemd/system/openclaw-ui-proxy.service
sudo sed -i "s/COGNITO_CLIENT_ID=REPLACE_ME/COGNITO_CLIENT_ID=$CLIENT_ID/" /etc/systemd/system/openclaw-ui-proxy.service
sudo systemctl daemon-reload
sudo systemctl restart openclaw-ui-proxy
```

## Step 6: Configure the Gateway

Update OpenClaw's gateway config with the CloudFront domain:

```bash
openclaw config patch "{
  \"gateway\": {
    \"controlUi\": {
      \"allowedOrigins\": [\"https://$CF_DOMAIN\"],
      \"allowInsecureAuth\": true
    }
  }
}"
```

- `allowedOrigins` — required for non-loopback WebSocket connections
- `allowInsecureAuth` — required because the proxy connects to the gateway over HTTP (not HTTPS)

> **Note on `basePath`:** If you want the UI at a subpath (e.g. `/ui`), set `gateway.controlUi.basePath: "/ui"` and adjust the proxy paths and ALB routing accordingly. For a dedicated CloudFront distribution, no basePath is needed — the UI lives at the root.

## Step 7: Verify the Automated Setup

Before involving the user, verify everything works:

```bash
# 1. Proxy is running
curl -s http://localhost:3102/health
# → {"status":"ok",...}

# 2. ALB target is healthy
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --region us-east-1 \
  --query 'TargetHealthDescriptions[0].TargetHealth.State'
# → "healthy"

# 3. CloudFront is deployed
aws cloudfront get-distribution --id "$CF_ID" --region us-east-1 \
  --query 'Distribution.Status'
# → "Deployed"

# 4. Unauthenticated request redirects to login
curl -s -o /dev/null -w "%{http_code}" "https://$CF_DOMAIN/"
# → 302 (redirect to /login → Cognito)
```

## Step 8: Guide the User Through Manual Steps

**This part cannot be automated.** You must walk the user through these browser steps. Send them a message like this:

---

> ✅ The OpenClaw Control UI is deployed! Here's your URL:
>
> **https://YOUR_CF_DOMAIN**
>
> **Three one-time setup steps in your browser:**
>
> **1. Log in with Cognito**
> Open the URL above. You'll be redirected to the Cognito login page. Enter your credentials.
>
> **2. Paste the gateway token**
> After login, the Control UI loads but shows "gateway token missing." Open the settings panel (gear icon) and paste this token:
>
> `YOUR_GATEWAY_TOKEN`
>
> This is saved in your browser — you only do this once.
>
> **3. Device pairing**
> After pasting the token, the UI may show "pairing required." Tell me when you see this and I'll approve your device.

---

**When the user reports "pairing required"**, run:

```bash
# List pending pairing requests
openclaw devices list

# Approve the pending request
openclaw devices approve REQUEST_ID
```

The user should see the Control UI connect immediately after approval. Device pairing is per-browser — each new browser or cleared browser data requires re-approval.

## Troubleshooting

### Proxy returns 302 loop
- Cognito token exchange may be failing. Check proxy logs: `journalctl -u openclaw-ui-proxy -f`
- Verify callback URL in Cognito matches exactly: `https://YOUR_CF_DOMAIN/callback`

### ALB target unhealthy
- EC2 security group must allow port 3102 from the ALB security group
- Proxy must be running: `systemctl status openclaw-ui-proxy`
- Health endpoint must work: `curl http://localhost:3102/health`

### CloudFront shows old content or wrong page
- Invalidate cache: `aws cloudfront create-invalidation --distribution-id $CF_ID --paths "/*"`

### WebSocket won't connect
- CloudFront and ALB both support WebSocket natively (no special config)
- `gateway.controlUi.allowedOrigins` must include your CloudFront domain (exact match with `https://`)
- `gateway.controlUi.allowInsecureAuth` must be `true`

### redirect_uri uses http:// instead of https://
- The proxy hardcodes `https://` in redirect URIs because CloudFront terminates TLS and ALB sees HTTP. If you see `http://`, check the `getRedirectUri` function.

### "pairing required" keeps appearing
- Each browser profile gets a unique device ID. Clearing browser data = new device = re-pairing.
- Run `openclaw devices list` to see and approve pending requests.

## AWS Managed Policy IDs

These are AWS-managed CloudFront policies (same in all accounts):

| Policy | ID | Purpose |
|---|---|---|
| CachingDisabled | `4135ea2d-6df8-44a3-9df3-4b5a84be39ad` | No caching — required for dynamic + WebSocket |
| AllViewer (Origin Request) | `216adef6-5c7f-47e4-b989-5492eafa07d3` | Forward all headers/cookies/query strings to origin |

## Security Notes

- ALB security group **must** restrict inbound to CloudFront managed prefix list only. Never `0.0.0.0/0`.
- Cognito tokens are stored as `HttpOnly; Secure; SameSite=Lax` cookies — not accessible to client-side JavaScript.
- The gateway token is a second independent auth layer.
- Device pairing is a third layer — each new browser must be explicitly approved by the operator.
- The gateway remains on loopback (`127.0.0.1`) — never exposed to the network.
- The proxy itself has no secrets hardcoded — Cognito config comes from environment variables.
