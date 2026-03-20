# App Registry — Architecture Pattern

A DynamoDB-based application catalog that serves as the **single source of truth** for all apps in an AWS account. Any service that needs to know "what apps exist?" reads from this table instead of hardcoding lists.

## Why

When you build 10+ apps in one account, you need a central registry. Otherwise every dashboard, monitoring check, and diagram generator hardcodes its own app list — and they all drift.

The app registry pattern solves this:

* **Add an app = insert a DynamoDB row** — no code changes, no deploys
* **Every consumer reads the same table** — dashboards, health checks, diagram generators, CLI tools
* **Rich metadata** — URL, stack, VPC, CloudFront ID, Cognito client, version, links, diagram context

## DynamoDB Table Design

* **Table name:** `app-registry` (or your chosen name)
* **Billing:** PAY_PER_REQUEST (low read volume)
* **Key:** `appId` (String, HASH) — no sort key needed

### Schema

| Attribute | Type | Required | Description |
|-----------|------|----------|-------------|
| `appId`   | S    | ✅        | Unique identifier (e.g., `my-app`, `grafana`) |
| `name`    | S    | ✅        | Display name |
| `url`     | S    | ✅        | Primary URL (CloudFront). `N/A` for non-web apps |
| `description` | S    | —        | What the app does |
| `stack`   | S    | —        | Tech stack summary (e.g., "ECS+DynamoDB+Lambda") |
| `vpc`     | S    | —        | VPC name or `None` for serverless |
| `vpcCidr` | S    | —        | VPC CIDR block |
| `cloudfront` | S    | —        | CloudFront distribution ID |
| `cognitoClient` | S    | —        | Cognito app client ID |
| `repo`    | S    | —        | Source repo name |
| `version` | S    | —        | Current deployed version |
| `created` | S    | —        | Creation date (YYYY-MM-DD) |
| `icon`    | S    | —        | Emoji icon for UI cards |
| `headerColor` | S    | —        | RGBA color for card styling |
| `links`   | L    | —        | Array of `{label, url, icon}` quick-link buttons |
| `diagramContext` | S    | —        | Component description for diagram generation |

### Why These Fields

* `**stack**` — at-a-glance architecture without clicking into anything
* `**links**` — extensible quick-link buttons (repo, console, docs) without schema changes
* `**diagramContext**` — free-text component list so diagram generators work without parsing infrastructure
* `**headerColor**` — UI styling in data, not code. Add new apps without touching frontend

## Architecture

```
                       ┌───────────────────────────┐
                       │  app-registry (DynamoDB)   │
                       │  PAY_PER_REQUEST, String PK│
                       └─────────────┬─────────────┘
                                     │
           ┌────────────┬────────────┼────────────┬──────────────┐
           │            │            │            │              │
           ▼            ▼            ▼            ▼              ▼
     ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
     │Dashboard │ │ API GW + │ │ Diagram  │ │ Health   │ │  CLI /   │
     │  (ECS)   │ │  Lambda  │ │Generator │ │ Checks   │ │  Agent   │
     │  SigV4   │ │ (public) │ │ (Lambda) │ │ (cron)   │ │  tools   │
     └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘
```

## Consumer Patterns

### 1. Dashboard / UI (ECS Fargate)

The infrastructure dashboard reads the registry via API Gateway with SigV4 auth:

```typescript
// SigV4-signed request from ECS task
const response = await sigv4Fetch(
  `https://${API_GW_ID}.execute-api.${REGION}.amazonaws.com/prod/apps`
);
const apps = await response.json();
```

**IAM:** ECS task role needs `execute-api:Invoke` on the API Gateway resource.

### 2. API Lambda (thin proxy)

A simple Lambda that scans DynamoDB and returns all items:

```javascript
const { DynamoDBClient, ScanCommand } = require('@aws-sdk/client-dynamodb');
const client = new DynamoDBClient({});

exports.handler = async () => {
  const result = await client.send(new ScanCommand({ TableName: 'app-registry' }));
  return {
    statusCode: 200,
    body: JSON.stringify(result.Items),
  };
};
```

**Auth:** AWS_IAM (SigV4) — not Cognito. SigV4 is reliable for server-to-server; Cognito authorizers can be flaky for this pattern.

### 3. Diagram Generator

Reads `diagramContext` field to generate architecture diagrams without parsing actual infrastructure:

```javascript
const app = await getItem('app-registry', { appId: 'my-app' });
const context = app.diagramContext; // "Components: CloudFront, ALB, ECS Fargate..."
await generateDiagram(context);
```

### 4. Health Checks / Monitoring

Periodic job scans table, hits each URL, alerts on failures:

```bash
# Get all app URLs
aws dynamodb scan --table-name app-registry \
  --projection-expression "appId,#u" \
  --expression-attribute-names '{"#u":"url"}' \
  --query 'Items[*].{id:appId.S,url:url.S}'

# Then curl each URL and check for HTTP 200
```

### 5. CLI Tools

Direct DynamoDB reads from CLI tools or agent scripts:

```bash
# List all apps
aws dynamodb scan --table-name app-registry \
  --projection-expression "appId,#n,#u,stack" \
  --expression-attribute-names '{"#n":"name","#u":"url"}'

# Get one app
aws dynamodb get-item --table-name app-registry \
  --key '{"appId":{"S":"my-app"}}'
```

## IAM Policies

### Read-only (for Lambdas, diagram generators)

```json
{
  "Effect": "Allow",
  "Action": ["dynamodb:Scan", "dynamodb:GetItem", "dynamodb:Query"],
  "Resource": "arn:aws:dynamodb:REGION:ACCOUNT:table/app-registry"
}
```

### API Gateway invoke (for ECS tasks)

```json
{
  "Effect": "Allow",
  "Action": ["execute-api:Invoke"],
  "Resource": "arn:aws:execute-api:REGION:ACCOUNT:API_ID/prod/GET/apps"
}
```

## Setting It Up

### 1. Create the table

```bash
aws dynamodb create-table \
  --table-name app-registry \
  --attribute-definitions AttributeName=appId,AttributeType=S \
  --key-schema AttributeName=appId,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

### 2. Add your first app

```bash
aws dynamodb put-item --table-name app-registry \
  --item '{
    "appId": {"S": "my-app"},
    "name": {"S": "My Application"},
    "url": {"S": "https://xxxx.cloudfront.net"},
    "stack": {"S": "ECS+DynamoDB"},
    "created": {"S": "2026-01-01"},
    "icon": {"S": "🚀"},
    "description": {"S": "What this app does"}
  }'
```

### 3. Create the API Lambda + API Gateway

* Lambda: Node.js, ARM64, 128MB, 10s timeout
* API Gateway: REST API with IAM auth
* Attach `app-registry-read` policy to Lambda role

### 4. Grant consumers access

* Dashboard ECS task role → `execute-api:Invoke`
* Diagram Lambdas → `dynamodb:Scan/GetItem`
* Health check scripts → `dynamodb:Scan`

## Design Decisions


1. **DynamoDB over config files** — no deploys to add/update apps, instant propagation
2. **SigV4 over Cognito for API auth** — server-to-server is more reliable with IAM
3. **Free-text** `**diagramContext**` — flexible, no rigid schema for component descriptions
4. `**links**` **as List type** — extensible quick-links without schema migrations
5. **Styling in data** — `headerColor`, `icon` live in DynamoDB so UI doesn't need code changes per app
6. **PAY_PER_REQUEST** — reads are infrequent (dashboard loads, health checks), no capacity planning needed

## Cost

Effectively free. A 17-item table with a few hundred reads/day costs < $0.01/month on PAY_PER_REQUEST.