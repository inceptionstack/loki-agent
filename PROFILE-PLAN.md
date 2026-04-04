# PROFILE-PLAN.md — Permission Profiles for Loki Agent

## Overview

Profiles control the **IAM permissions** and **instance sizing defaults** for a Loki deployment. They are orthogonal to packs — any pack can be combined with any profile.

```
Pack   = WHAT agent runtime gets installed (openclaw, claude-code, hermes, pi, ironclaw)
Profile = WHAT the agent is ALLOWED TO DO on AWS (builder, account_assistant, personal_assistant)
```

## Profiles

### `builder` — Full-stack AWS builder
The current behavior. Agent can create, modify, and delete any AWS resource.

| Attribute | Value |
|-----------|-------|
| **IAM** | `AdministratorAccess` (managed policy) |
| **Instance default** | `t4g.xlarge` |
| **Use case** | Build apps, deploy infrastructure, manage pipelines, fix production issues |
| **Risk** | High — can break anything in the account |

### `account_assistant` — Read-only AWS advisor
Can see everything, change nothing. Useful for cost analysis, architecture review, debugging, compliance checks.

| Attribute | Value |
|-----------|-------|
| **IAM** | `ReadOnlyAccess` (managed policy) + explicit Deny on secrets/S3 object reads (see below) |
| **Instance default** | `t4g.medium` |
| **Use case** | Budget advice, architecture review, debugging help, security posture review |
| **Risk** | Low — cannot modify any resources, cannot read secret values or S3 data |

**Deny policy (inline, attached to the role):**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenySecretValues",
      "Effect": "Deny",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:GetResourcePolicy",
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyS3ObjectAccess",
      "Effect": "Deny",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetObjectAcl"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyLambdaCodeAccess",
      "Effect": "Deny",
      "Action": [
        "lambda:GetFunction"
      ],
      "Resource": "*"
    }
  ]
}
```

> **Note:** The agent can still `s3:ListBucket`, `s3:GetBucketLocation`, etc. — it can see what buckets and objects exist, just can't read their contents. Same for secrets — can list them, can't read values. `lambda:GetFunction` is denied because it returns a presigned URL to download function code + env vars that may contain secrets. `lambda:ListFunctions` and `lambda:GetFunctionConfiguration` remain available.
>
> **Intentionally allowed:** `ssm:GetParameterHistory`, `codecommit:GetFile/GetBlob`, `ecr:BatchGetImage`, `logs:GetLogEvents` — these are useful for debugging and architecture review, which is the profile's purpose.

### `personal_assistant` — Non-AWS personal helper
No AWS access at all (except Bedrock for inference). For daily productivity, writing, research, scheduling — not AWS work.

| Attribute | Value |
|-----------|-------|
| **IAM** | Bedrock invoke only + SSM (for connectivity) |
| **Instance default** | `t4g.medium` |
| **Use case** | Personal assistant, writing, research, coding help (non-AWS) |
| **Risk** | Minimal — cannot interact with any AWS service except Bedrock |

**IAM policy:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockInference",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:GetUseCaseForModelAccess"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SSMConnectivity",
      "Effect": "Allow",
      "Action": [
        "ssm:UpdateInstanceInformation",
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
        "ec2messages:AcknowledgeMessage",
        "ec2messages:DeleteMessage",
        "ec2messages:FailMessage",
        "ec2messages:GetEndpoint",
        "ec2messages:GetMessages",
        "ec2messages:SendReply"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BedrockDiscovery",
      "Effect": "Allow",
      "Action": [
        "bedrock:ListFoundationModels",
        "bedrock:GetFoundationModel",
        "bedrock:ListInferenceProfiles"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Identity",
      "Effect": "Allow",
      "Action": [
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

> **Note:** Agent still has full local shell access on the EC2 instance — can install packages, run code, manage files, etc. It just can't call AWS APIs (except Bedrock + SSM).
>
> **All profiles also get bootstrap permissions** (scoped, for deployment only):
> ```json
> {
>   "Sid": "BootstrapOperations",
>   "Effect": "Allow",
>   "Action": [
>     "ssm:PutParameter",
>     "ssm:DeleteParameter",
>     "cloudformation:SignalResource"
>   ],
>   "Resource": [
>     "arn:aws:ssm:*:*:parameter/loki/*",
>     "arn:aws:cloudformation:*:*:stack/*"
>   ]
> }
> ```
> These are needed by bootstrap.sh for status publishing and cfn-signal. Scoped to `/loki/*` SSM parameters so the agent can't write arbitrary params post-bootstrap.

## Bedrockify Dependency

**All profiles need Bedrockify installed.** Bedrockify (OpenAI-compatible proxy for Bedrock) is a base dependency that most packs rely on. Profile controls IAM permissions, not what software gets installed. The pack system handles dependencies via `registry.yaml` — if a pack lists `bedrockify` as a dep, it gets installed regardless of profile.

`account_assistant` uses `ReadOnlyAccess` which does NOT include Bedrock invoke permissions. Since the agent still needs inference, add a Bedrock statement alongside the managed policy:

```json
{
  "Sid": "BedrockInference",
  "Effect": "Allow",
  "Action": [
    "bedrock:InvokeModel",
    "bedrock:InvokeModelWithResponseStream",
    "bedrock:GetUseCaseForModelAccess",
    "bedrock:ListFoundationModels",
    "bedrock:GetFoundationModel",
    "bedrock:ListInferenceProfiles"
  ],
  "Resource": "*"
}
```

## Implementation Plan

### Phase 1: Profile Registry

Create `profiles/` directory with one YAML manifest per profile:

```
profiles/
  registry.yaml          # Profile metadata + defaults
  builder.yaml           # IAM policy document
  account_assistant.yaml # IAM policy document + deny policy
  personal_assistant.yaml # IAM policy document
```

**`profiles/registry.yaml`:**
```yaml
profiles:
  builder:
    description: "Full-stack AWS builder — can create, modify, and delete any AWS resource"
    instance_type: t4g.xlarge
    iam_mode: managed              # Use AWS managed policy
    managed_policies:
      - arn:aws:iam::aws:policy/AdministratorAccess
    deny_policies: []
    security_services: true        # Enable security services by default

  account_assistant:
    description: "Read-only AWS advisor — can see everything, change nothing"
    instance_type: t4g.medium
    iam_mode: managed
    managed_policies:
      - arn:aws:iam::aws:policy/ReadOnlyAccess
    inline_policies:
      - profiles/account_assistant_bedrock.json
    deny_policies:
      - profiles/account_assistant_deny.json
    bootstrap_policies:
      - profiles/bootstrap_operations.json
    security_services: true

  personal_assistant:
    description: "Personal helper — Bedrock inference only, no AWS access"
    instance_type: t4g.medium
    iam_mode: inline               # Custom inline policy
    inline_policies:
      - profiles/personal_assistant.json
    bootstrap_policies:
      - profiles/bootstrap_operations.json
    deny_policies: []
    security_services: false       # No point enabling if agent can't read them
```

### Phase 2: CloudFormation Template Changes

**New parameter:**
```yaml
Parameters:
  ProfileName:
    Type: String
    AllowedValues:
      - builder
      - account_assistant
      - personal_assistant
    Description: "Permission profile. 'builder' = full admin. 'account_assistant' = read-only. 'personal_assistant' = Bedrock only."
    # No Default — must be explicitly specified
```

**Conditional IAM role:**
```yaml
Conditions:
  IsBuilder: !Equals [!Ref ProfileName, 'builder']
  IsNotBuilder: !Not [!Condition IsBuilder]
  IsAccountAssistant: !Equals [!Ref ProfileName, 'account_assistant']
  IsPersonalAssistant: !Equals [!Ref ProfileName, 'personal_assistant']
  NeedsAdminUser: !Condition IsBuilder

Resources:
  InstanceRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${EnvironmentName}-role'
      AssumeRolePolicyDocument: ...
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
        - !If [IsBuilder, 'arn:aws:iam::aws:policy/AdministratorAccess', !Ref 'AWS::NoValue']
        - !If [IsAccountAssistant, 'arn:aws:iam::aws:policy/ReadOnlyAccess', !Ref 'AWS::NoValue']

  # Bootstrap operations for non-builder profiles (SSM status + cfn-signal)
  BootstrapOperationsPolicy:
    Type: AWS::IAM::Policy
    Condition: IsNotBuilder  # Builder has AdministratorAccess, doesn't need this
    Properties:
      PolicyName: !Sub '${EnvironmentName}-bootstrap-ops'
      Roles: [!Ref InstanceRole]
      PolicyDocument:
        # (bootstrap_operations.json — scoped ssm:PutParameter + cfn:SignalResource)

  # Bedrock inference for account_assistant (ReadOnlyAccess doesn't include invoke)
  AccountAssistantBedrockPolicy:
    Type: AWS::IAM::Policy
    Condition: IsAccountAssistant
    Properties:
      PolicyName: !Sub '${EnvironmentName}-bedrock-inference'
      Roles: [!Ref InstanceRole]
      PolicyDocument:
        # (account_assistant_bedrock.json — Bedrock invoke + discovery)

  # Deny policy for account_assistant (secrets + S3 objects + lambda code)
  AccountAssistantDenyPolicy:
    Type: AWS::IAM::Policy
    Condition: IsAccountAssistant
    Properties:
      PolicyName: !Sub '${EnvironmentName}-deny-secrets-s3'
      Roles: [!Ref InstanceRole]
      PolicyDocument:
        # (deny policy JSON from above)

  # Inline policy for personal_assistant (Bedrock + SSM only)
  PersonalAssistantPolicy:
    Type: AWS::IAM::Policy
    Condition: IsPersonalAssistant
    Properties:
      PolicyName: !Sub '${EnvironmentName}-bedrock-only'
      Roles: [!Ref InstanceRole]
      PolicyDocument:
        # (Bedrock + SSM + STS policy JSON from above)

  # Admin user — only for builder profile
  AdminUser:
    Type: AWS::IAM::User
    Condition: NeedsAdminUser
    ...
```

**Instance type default from profile:**

The instance type parameter keeps its current allowed values, but the install.sh changes the *default* based on profile. In the template itself, `InstanceType` remains user-overridable.

**Security services conditional on profile:**

Skip security service Lambda invocation for `personal_assistant` (agent can't read findings anyway). Bedrock Form Lambda runs for ALL profiles since every profile needs inference.

### Phase 3: Terraform Changes

Mirror the CFN changes in `deploy/terraform/`:

```hcl
variable "profile_name" {
  type        = string
  description = "Permission profile"
  validation {
    condition     = contains(["builder", "account_assistant", "personal_assistant"], var.profile_name)
    error_message = "Must be one of: builder, account_assistant, personal_assistant"
  }
  # No default — must be specified
}

# Conditional managed policy attachments
resource "aws_iam_role_policy_attachment" "admin" {
  count      = var.profile_name == "builder" ? 1 : 0
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy_attachment" "readonly" {
  count      = var.profile_name == "account_assistant" ? 1 : 0
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Deny policy for account_assistant
resource "aws_iam_role_policy" "account_assistant_deny" {
  count  = var.profile_name == "account_assistant" ? 1 : 0
  name   = "${var.environment_name}-deny-secrets-s3"
  role   = aws_iam_role.instance.id
  policy = file("${path.module}/policies/account_assistant_deny.json")
}

# Inline policy for personal_assistant
resource "aws_iam_role_policy" "personal_assistant" {
  count  = var.profile_name == "personal_assistant" ? 1 : 0
  name   = "${var.environment_name}-bedrock-only"
  role   = aws_iam_role.instance.id
  policy = file("${path.module}/policies/personal_assistant.json")
}
```

### Phase 4: Installer (`install.sh`) Changes

**New `--profile` flag:**
```bash
--profile)
  if [[ $# -lt 2 || "$2" == --* ]]; then
    echo "✗ --profile requires a value (builder, account_assistant, personal_assistant)" >&2
    exit 1
  fi
  PRESELECT_PROFILE="$2"; shift 2 ;;
```

**Profile selection — REQUIRED, no default:**

New function `choose_profile()` called early in `collect_config`:

```bash
choose_profile() {
  if [[ -n "${PRESELECT_PROFILE}" ]]; then
    # validate against registry
    ...
    ok "Profile pre-selected: ${PROFILE_NAME}"
    return
  fi

  echo ""
  echo "  Permission profiles (REQUIRED — choose one):"
  echo ""
  echo "    1) builder             — Full admin access. Can create, modify, delete any AWS resource."
  echo "                             Best for: building apps, deploying infra, managing pipelines."
  echo ""
  echo "    2) account_assistant   — Read-only. Can see everything, change nothing."
  echo "                             Best for: cost analysis, architecture review, debugging help."
  echo ""
  echo "    3) personal_assistant  — Bedrock only. No AWS access."
  echo "                             Best for: writing, research, coding help, daily tasks."
  echo ""

  if [[ "$AUTO_YES" == true ]]; then
    # Non-interactive mode WITHOUT --profile → error, don't guess
    fail "Profile is required. Use --profile <builder|account_assistant|personal_assistant>"
  fi

  prompt "Select profile" PROFILE_CHOICE ""
  # ... validate and set PROFILE_NAME
}
```

> **Key design decision:** `--non-interactive` without `--profile` is an **error**. We don't pick a default because the wrong profile has security implications. Interactive mode shows the menu and waits.

**Instance size default adjusts per profile:**

```bash
# In collect_config(), after profile is selected:
case "$PROFILE_NAME" in
  builder)              default_size_choice="3" ;;  # t4g.xlarge
  account_assistant)    default_size_choice="1" ;;  # t4g.medium
  personal_assistant)   default_size_choice="1" ;;  # t4g.medium
esac
```

**Parameter plumbing:**

Add `ProfileName` / `profile_name` to:
- `PARAM_CFN_NAMES` / `PARAM_TF_NAMES` / `PARAM_VALUES` arrays
- `format_console_params()`, `format_cfn_cli_params()`, `format_tf_vars()`
- Deploy summary display

### Phase 5: Bootstrap (`deploy/bootstrap.sh`) Changes

Bootstrap needs a new `--profile` argument and profile-aware branching:

1. **Add `--profile` to arg parsing** in bootstrap.sh (alongside `--pack`, `--region`, etc.)

2. **Thread `--profile` through UserData in BOTH deploy methods:**
   - **CFN template UserData:** add `export PROFILE_NAME="${ProfileName}"` and `--profile "$PROFILE_NAME"` to the bootstrap.sh call
   - **Terraform `userdata.sh.tpl`:** add `profile_name` template var and `--profile "$PROFILE_NAME"` to the bootstrap.sh call

3. **Write profile to a marker file** so the agent knows its own profile:
```bash
echo "${PROFILE_NAME}" > /home/ec2-user/.openclaw/workspace/.profile
```

4. **Conditionally adjust brain files** based on profile. E.g., `personal_assistant` gets a different `SOUL.md` that says "you have no AWS access" and `TOOLS.md` that omits AWS tooling.

5. **Skip security service checks** for `personal_assistant` profile (agent can't read findings). Bedrock connectivity check runs for ALL profiles since all need inference.

### Phase 6: Registry Integration

Add `ProfileName` to:
- `packs/registry.json` — for the installer to pass through
- CFN template `AllowedValues`
- Terraform `validation` block
- Loki watermark tags (so `uninstall.sh` can show profile info)

### File Changes Summary

| File | Change |
|------|--------|
| `profiles/registry.yaml` | **NEW** — profile metadata |
| `profiles/account_assistant_deny.json` | **NEW** — deny policy (secrets, S3, lambda code) |
| `profiles/account_assistant_bedrock.json` | **NEW** — Bedrock invoke for account_assistant |
| `profiles/personal_assistant.json` | **NEW** — Bedrock-only policy |
| `profiles/bootstrap_operations.json` | **NEW** — scoped SSM + cfn-signal for bootstrap |
| `install.sh` | Add `--profile` flag, `choose_profile()`, require profile, instance defaults |
| `deploy/cloudformation/template.yaml` | Add `ProfileName` param, conditional IAM, conditional security services, AdminUser gated on IsBuilder |
| `deploy/terraform/main.tf` | Add `profile_name` var, conditional IAM resources |
| `deploy/terraform/variables.tf` | Add `profile_name` variable |
| `deploy/terraform/policies/` | **NEW** — JSON policy files |
| `deploy/terraform/userdata.sh.tpl` | Pass `--profile` to bootstrap.sh |
| `deploy/bootstrap.sh` | Add `--profile` arg, write `.profile` marker, profile-aware branching (skip security checks for personal_assistant) |
| `uninstall.sh` | Display profile tag in deployment list |
| `README.md` | Document profiles, update TL;DR examples, add profile table |

### Implementation Order

1. **Create profile policy files** (JSON) — can validate independently
2. **CFN template** — add parameter + conditionals, test with `aws cloudformation validate-template`
3. **Terraform** — add variable + conditionals, test with `terraform validate`
4. **install.sh** — add `--profile` flag + selection + plumbing
5. **bootstrap.sh** — profile marker + conditional brain
6. **README.md** — document everything
7. **Test matrix:** 3 profiles × 2 methods (cfn, terraform) = 6 deploys

### Example Usage After Implementation

```sh
# Full builder (current behavior, explicit)
bash install.sh --non-interactive --pack openclaw --method cfn --profile builder

# Read-only assistant for cost/architecture review
bash install.sh --non-interactive --pack openclaw --method terraform --profile account_assistant

# Personal assistant (Bedrock only, no AWS)
bash install.sh --non-interactive --pack claude-code --method cfn --profile personal_assistant

# Interactive — profile menu shown, must pick one
bash install.sh
```

### Open Questions — RESOLVED

1. **Should `account_assistant` be allowed to read CloudWatch logs/metrics?** **YES** — ReadOnlyAccess includes it, keep it. Logs/metrics are essential for debugging and cost analysis.

2. **Should `personal_assistant` have `sts:GetCallerIdentity`?** **YES** — add it to the personal_assistant policy. Agent needs to know what account it's in for basic context.

3. **Profile upgrade/downgrade path?** **Redeploy for now.** Stack update would work technically (IAM changes don't replace instances), but redeploy is simpler and safer for v1. Can add upgrade-in-place later.

4. **Should profile be a tag on the instance?** **YES** — tag as `loki:profile` on the instance and VPC. Useful for `uninstall.sh` visibility and agent self-identification.
