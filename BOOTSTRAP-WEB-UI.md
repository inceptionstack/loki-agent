# BOOTSTRAP-WEB-UI.md — Expose OpenClaw Control UI via CloudFront + Cognito

This guide exposes the OpenClaw Gateway's built-in Control UI (Vite + Lit SPA) through CloudFront, secured by Cognito authentication. The gateway stays on loopback — a Node.js proxy on the same EC2 instance handles Cognito JWT validation and proxies HTTP + WebSocket traffic to the gateway.

## Architecture

```
Browser (HTTPS)
    ↓
CloudFront (TLS termination, no caching)
    ↓  /ui* behavior → ALB origin
ALB (HTTP, port 80)
    ↓  path rule: /ui, /ui/* → target group (port 3102)
Node.js Proxy (EC2, port 3102)
    ↓  validates Cognito JWT cookie
    ↓  proxies HTTP + WebSocket
Gateway (127.0.0.1:18789)
```

**Auth layers:**
1. CloudFront → ALB security group (only CloudFront IPs allowed)
2. Proxy → Cognito JWT validation (JWKS)
3. Gateway → its own bearer token (user pastes once in UI settings)

## Prerequisites

- EC2 instance running OpenClaw with gateway on loopback (`gateway.bind: "loopback"`)
- AWS Cognito User Pool with a Hosted UI domain configured
- Node.js 20+ on the EC2 instance
- An existing CloudFront distribution + ALB setup (or create new ones — instructions below cover both)

## Step 1: Configure the Gateway

Set `controlUi.basePath` to `/ui` so the gateway serves its UI assets under that prefix. Add your CloudFront domain to `allowedOrigins` and enable `allowInsecureAuth` (needed because the proxy connects from localhost over HTTP):

```bash
# Via OpenClaw CLI
openclaw config patch '{
  "gateway": {
    "controlUi": {
      "basePath": "/ui",
      "allowedOrigins": ["https://YOUR_CLOUDFRONT_DOMAIN"],
      "allowInsecureAuth": true
    }
  }
}'
```

Or edit `~/.openclaw/openclaw.json` directly and restart:

```json5
{
  "gateway": {
    "controlUi": {
      "basePath": "/ui",
      "allowedOrigins": ["https://YOUR_CLOUDFRONT_DOMAIN"],
      "allowInsecureAuth": true
    }
  }
}
```

## Step 2: Create the Proxy

The proxy handles:
- Cognito OAuth2 code flow (login redirect → token exchange → httpOnly cookie)
- JWT verification on every request using JWKS
- HTTP proxy to gateway for static assets
- WebSocket upgrade proxy for the Control UI's real-time connection

### Install dependencies

```bash
mkdir -p /tmp/openclaw-ui-proxy && cd /tmp/openclaw-ui-proxy

cat > package.json << 'EOF'
{
  "name": "openclaw-ui-proxy",
  "version": "1.0.0",
  "type": "module",
  "dependencies": {
    "@aws-sdk/client-secrets-manager": "^3.700.0",
    "http-proxy": "^1.18.1",
    "jose": "^6.0.0"
  }
}
EOF

npm install
```

### Proxy source (`server.mjs`)

```javascript
import http from 'node:http';
import httpProxy from 'http-proxy';
import * as jose from 'jose';

// ── Config ───────────────────────────────────────────────────────────────────
const PORT = parseInt(process.env.PORT || '3102', 10);
const COGNITO_REGION = process.env.COGNITO_REGION || 'us-east-1';
const COGNITO_POOL_ID = process.env.COGNITO_POOL_ID;          // e.g. us-east-1_AbCdEfGhI
const COGNITO_DOMAIN = process.env.COGNITO_DOMAIN;            // e.g. my-app.auth.us-east-1.amazoncognito.com
const COGNITO_CLIENT_ID = process.env.COGNITO_CLIENT_ID;      // Cognito app client ID
const GATEWAY_TARGET = process.env.GATEWAY_TARGET || 'http://127.0.0.1:18789';

const COGNITO_ISSUER = `https://cognito-idp.${COGNITO_REGION}.amazonaws.com/${COGNITO_POOL_ID}`;
const JWKS_URL = `${COGNITO_ISSUER}/.well-known/jwks.json`;

// ── JWKS / JWT Verification ──────────────────────────────────────────────────
const JWKS = jose.createRemoteJWKSet(new URL(JWKS_URL));

async function verifyJwt(token) {
  const { payload } = await jose.jwtVerify(token, JWKS, { issuer: COGNITO_ISSUER });
  return payload;
}

// ── Cookie Parser ────────────────────────────────────────────────────────────
function parseCookies(cookieHeader) {
  const cookies = {};
  if (!cookieHeader) return cookies;
  cookieHeader.split(';').forEach((c) => {
    const [name, ...rest] = c.trim().split('=');
    if (name) cookies[name] = rest.join('=');
  });
  return cookies;
}

// ── Build redirect URI ───────────────────────────────────────────────────────
function getRedirectUri(req) {
  const host = req.headers['x-forwarded-host'] || req.headers.host;
  // Always https — CloudFront terminates TLS, ALB forwards as http
  return `https://${host}/ui/callback`;
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

// ── Auth check (shared by HTTP + WS) ────────────────────────────────────────
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

// ── HTTP Server ──────────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  // Health check (no auth — ALB hits this directly)
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ status: 'ok', ts: Date.now() }));
  }

  // Only handle /ui paths
  if (!req.url.startsWith('/ui')) {
    res.writeHead(404);
    return res.end('Not found');
  }

  // Login redirect → Cognito Hosted UI
  if (req.url === '/ui/login') {
    const redirectUri = getRedirectUri(req);
    const loginUrl = `https://${COGNITO_DOMAIN}/login?response_type=code&client_id=${COGNITO_CLIENT_ID}&redirect_uri=${encodeURIComponent(redirectUri)}&scope=openid+email+profile`;
    res.writeHead(302, { Location: loginUrl });
    return res.end();
  }

  // OAuth callback — exchange code for tokens, set cookie
  if (req.url.startsWith('/ui/callback')) {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const code = url.searchParams.get('code');
    if (!code) {
      res.writeHead(302, { Location: '/ui/login' });
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
        res.writeHead(302, { Location: '/ui/login' });
        return res.end();
      }

      const tokens = await tokenRes.json();
      const maxAge = tokens.expires_in || 3600;
      res.writeHead(302, {
        Location: '/ui',
        'Set-Cookie': `oc_id_token=${tokens.id_token}; Path=/ui; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAge}`,
      });
      return res.end();
    } catch (err) {
      console.error('[callback] error:', err.message);
      res.writeHead(302, { Location: '/ui/login' });
      return res.end();
    }
  }

  // Logout
  if (req.url === '/ui/logout') {
    res.writeHead(302, {
      Location: '/ui/login',
      'Set-Cookie': 'oc_id_token=; Path=/ui; HttpOnly; Secure; Max-Age=0',
    });
    return res.end();
  }

  // All other /ui paths — check Cognito auth, then proxy to gateway
  const authed = await checkAuth(req);
  if (!authed) {
    res.writeHead(302, { Location: '/ui/login' });
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
  console.log(`[openclaw-ui-proxy] proxying /ui/* to ${GATEWAY_TARGET}`);
});
```

### Install to /opt and create systemd service

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
Environment=AWS_REGION=us-east-1
Environment=COGNITO_REGION=us-east-1
Environment=COGNITO_POOL_ID=YOUR_POOL_ID
Environment=COGNITO_DOMAIN=YOUR_APP.auth.us-east-1.amazoncognito.com
Environment=COGNITO_CLIENT_ID=YOUR_CLIENT_ID
Environment=GATEWAY_TARGET=http://127.0.0.1:18789

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now openclaw-ui-proxy
```

Verify: `curl -s http://localhost:3102/health` should return `{"status":"ok",...}`.

## Step 3: Create the ALB

Create an Application Load Balancer that CloudFront will use as its origin. The ALB forwards HTTP traffic to the proxy.

```bash
# Get your VPC ID and subnet IDs (need at least 2 AZs)
VPC_ID="YOUR_VPC_ID"
SUBNET_1="YOUR_SUBNET_1"  # AZ-a
SUBNET_2="YOUR_SUBNET_2"  # AZ-b

# Create ALB security group — only allows CloudFront IPs
ALB_SG=$(aws ec2 create-security-group \
  --group-name openclaw-ui-alb-sg \
  --description "OpenClaw UI ALB - CloudFront only" \
  --vpc-id "$VPC_ID" \
  --region us-east-1 \
  --query 'GroupId' --output text)

# Allow inbound from CloudFront managed prefix list
CF_PREFIX_LIST=$(aws ec2 describe-managed-prefix-lists \
  --filters "Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing" \
  --region us-east-1 \
  --query 'PrefixLists[0].PrefixListId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":80,\"ToPort\":80,\"PrefixListIds\":[{\"PrefixListId\":\"$CF_PREFIX_LIST\"}]}]" \
  --region us-east-1

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

echo "ALB DNS: $ALB_DNS"
```

### Create target group and register instance

```bash
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

aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets Id=YOUR_INSTANCE_ID,Port=3102 \
  --region us-east-1
```

### Create listener with path-based routing

```bash
# Create listener with default action (404 for unmatched paths)
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-action Type=fixed-response,FixedResponseConfig='{StatusCode="404",ContentType="text/plain",MessageBody="Not found"}' \
  --region us-east-1 \
  --query 'Listeners[0].ListenerArn' --output text)

# Add /ui path rule
aws elbv2 create-rule \
  --listener-arn "$LISTENER_ARN" \
  --priority 10 \
  --conditions '[{"Field":"path-pattern","Values":["/ui","/ui/*"]}]' \
  --actions "[{\"Type\":\"forward\",\"TargetGroupArn\":\"$TG_ARN\"}]" \
  --region us-east-1
```

### Allow ALB to reach EC2 proxy

Add an inbound rule to the EC2 instance's security group allowing port 3102 from the ALB security group:

```bash
EC2_SG="YOUR_EC2_SECURITY_GROUP_ID"

aws ec2 authorize-security-group-ingress \
  --group-id "$EC2_SG" \
  --protocol tcp \
  --port 3102 \
  --source-group "$ALB_SG" \
  --region us-east-1
```

Wait ~30s for the ALB health check to pass:

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --region us-east-1 \
  --query 'TargetHealthDescriptions[0].TargetHealth.State'
# Should return "healthy"
```

## Step 4: Create CloudFront Distribution

Create a CloudFront distribution with the ALB as origin. Key requirements:
- **No caching** (CachingDisabled managed policy)
- **All HTTP methods** allowed (for WebSocket upgrade + API calls)
- **AllViewer origin request policy** (forwards cookies, headers, query strings — needed for auth cookies and WebSocket)

```bash
ALB_DNS="YOUR_ALB_DNS_NAME"  # From step 3

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

echo "CloudFront ID: $CF_ID"
echo "CloudFront Domain: $CF_DOMAIN"
```

> **If adding to an existing CloudFront distribution** (e.g., you already have one for a chat frontend), add a cache behavior instead:
>
> 1. Get current config: `aws cloudfront get-distribution-config --id YOUR_CF_ID`
> 2. Add a `/ui*` cache behavior pointing to the ALB origin with CachingDisabled + AllViewer policies
> 3. Update the distribution with the new config
>
> The `/ui*` path pattern routes to the ALB; all other paths continue to their existing origins.

**Wait for CloudFront to deploy** (~2-5 minutes):

```bash
aws cloudfront wait distribution-deployed --id "$CF_ID"
```

## Step 5: Configure Cognito

### Create app client (or update existing)

Your Cognito app client needs:
- **Allowed callback URL:** `https://YOUR_CF_DOMAIN/ui/callback`
- **Allowed sign-out URL:** `https://YOUR_CF_DOMAIN/ui`
- **OAuth flows:** Authorization code grant
- **OAuth scopes:** openid, email, profile

```bash
POOL_ID="YOUR_COGNITO_POOL_ID"
CF_DOMAIN="YOUR_CF_DOMAIN"  # e.g. d1234abcdef.cloudfront.net

# Create a new app client
CLIENT_ID=$(aws cognito-idp create-user-pool-client \
  --user-pool-id "$POOL_ID" \
  --client-name "openclaw-ui" \
  --no-generate-secret \
  --supported-identity-providers COGNITO \
  --callback-urls "https://$CF_DOMAIN/ui/callback" \
  --logout-urls "https://$CF_DOMAIN/ui" \
  --allowed-o-auth-flows code \
  --allowed-o-auth-scopes openid email profile \
  --allowed-o-auth-flows-user-pool-client \
  --explicit-auth-flows ALLOW_USER_SRP_AUTH ALLOW_REFRESH_TOKEN_AUTH \
  --region us-east-1 \
  --query 'UserPoolClient.ClientId' --output text)

echo "Cognito Client ID: $CLIENT_ID"
```

If updating an existing client, add the callback/logout URLs:

```bash
# Add callback URL to existing client
aws cognito-idp update-user-pool-client \
  --user-pool-id "$POOL_ID" \
  --client-id "$CLIENT_ID" \
  --callback-urls "https://$CF_DOMAIN/ui/callback" "https://existing-callback-url" \
  --logout-urls "https://$CF_DOMAIN/ui" "https://existing-logout-url" \
  --region us-east-1
```

### Update the systemd service with your Cognito values

```bash
sudo systemctl edit openclaw-ui-proxy --force
```

Set the environment variables:

```ini
[Service]
Environment=COGNITO_POOL_ID=us-east-1_YourPoolId
Environment=COGNITO_DOMAIN=your-app.auth.us-east-1.amazoncognito.com
Environment=COGNITO_CLIENT_ID=your-client-id
```

Then restart: `sudo systemctl restart openclaw-ui-proxy`

## Step 6: Update Gateway Allowed Origins

Now that you know your CloudFront domain, update the gateway config:

```bash
openclaw config patch "{
  \"gateway\": {
    \"controlUi\": {
      \"allowedOrigins\": [\"https://$CF_DOMAIN\"]
    }
  }
}"
```

## Step 7: Test

1. Open `https://YOUR_CF_DOMAIN/ui`
2. You should be redirected to the Cognito login page
3. Log in with your Cognito credentials
4. The OpenClaw Control UI loads
5. On first connect, paste the **gateway token** in the UI settings panel
   - This is the token from `gateway.auth.token` in your OpenClaw config
   - One-time paste — the UI stores it in browser session storage
6. The UI asks for **device pairing** approval:
   ```bash
   openclaw devices list      # see pending request
   openclaw devices approve REQUEST_ID
   ```
   This is also one-time per browser.

## Troubleshooting

### "pairing required" after connecting
The gateway requires device pairing for new browsers. Run `openclaw devices list` and `openclaw devices approve <requestId>`.

### CloudFront returns the wrong page (cached)
Invalidate the cache: `aws cloudfront create-invalidation --distribution-id YOUR_CF_ID --paths "/ui" "/ui/*"`

### ALB target unhealthy
- Check EC2 security group allows port 3102 from the ALB security group
- Check proxy is running: `systemctl status openclaw-ui-proxy`
- Check health endpoint: `curl http://localhost:3102/health`

### Cognito callback fails (redirect_uri mismatch)
- Verify the callback URL in Cognito matches exactly: `https://YOUR_CF_DOMAIN/ui/callback`
- Check the proxy env var `COGNITO_CLIENT_ID` matches the Cognito app client

### WebSocket fails to connect
- CloudFront supports WebSocket natively (no special config needed)
- ALB supports WebSocket natively via HTTP upgrade
- Verify `gateway.controlUi.allowedOrigins` includes your CloudFront domain
- Verify `gateway.controlUi.allowInsecureAuth` is `true` (proxy connects via HTTP)

### redirect_uri uses http:// instead of https://
The proxy forces `https://` in redirect URIs since CloudFront terminates TLS. If you see `http://`, check the `getRedirectUri` function in the proxy — it should hardcode `https://`.

## Security Notes

- The ALB security group **must** restrict inbound to CloudFront IPs only (managed prefix list). Never open to `0.0.0.0/0`.
- Cognito tokens are stored in `HttpOnly; Secure; SameSite=Lax` cookies — not accessible to JavaScript.
- The gateway token is a second auth layer — even if Cognito is compromised, the attacker still needs the gateway token.
- Device pairing is a third layer — each new browser must be explicitly approved.
- The gateway stays on loopback (`127.0.0.1`) — never exposed to the network.

## Managed Policy IDs Reference

| Policy | ID | Purpose |
|---|---|---|
| CachingDisabled | `4135ea2d-6df8-44a3-9df3-4b5a84be39ad` | No caching (required for dynamic content + WebSocket) |
| AllViewer (Origin Request) | `216adef6-5c7f-47e4-b989-5492eafa07d3` | Forwards all headers, cookies, query strings to origin |
| CloudFront Prefix List | `com.amazonaws.global.cloudfront.origin-facing` | Managed list of CloudFront edge IPs |
