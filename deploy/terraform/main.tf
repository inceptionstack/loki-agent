data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64"
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  loki_tags = {
    "loki:managed"       = "true"
    "loki:watermark"     = var.loki_watermark
    "loki:deploy-method" = "terraform"
    "loki:version"       = "1.0"
    "loki:pack"          = var.pack_name
    "loki:profile"       = var.profile_name
  }
  vpc_id    = var.existing_vpc_id != "" ? var.existing_vpc_id : (length(aws_vpc.main) > 0 ? aws_vpc.main[0].id : "")
  subnet_id = var.existing_subnet_id != "" ? var.existing_subnet_id : (length(aws_subnet.public) > 0 ? aws_subnet.public[0].id : "")
}

# Validate: if existing_vpc_id is set, existing_subnet_id must also be set (and vice versa)
resource "terraform_data" "vpc_subnet_validation" {
  count = var.existing_vpc_id != "" && var.existing_subnet_id == "" ? 1 : 0
  lifecycle {
    precondition {
      condition     = var.existing_subnet_id != ""
      error_message = "existing_subnet_id is required when existing_vpc_id is set."
    }
  }
}

resource "terraform_data" "subnet_vpc_validation" {
  count = var.existing_subnet_id != "" && var.existing_vpc_id == "" ? 1 : 0
  lifecycle {
    precondition {
      condition     = var.existing_vpc_id != ""
      error_message = "existing_vpc_id is required when existing_subnet_id is set."
    }
  }
}

# ============================================================================
# VPC & Networking
# ============================================================================
resource "aws_vpc" "main" {
  count                = var.existing_vpc_id == "" ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.loki_tags, {
    Name = "${var.environment_name}-vpc"
  })
}

resource "aws_internet_gateway" "main" {
  count  = var.existing_vpc_id == "" ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  tags = merge(local.loki_tags, {
    Name = "${var.environment_name}-igw"
  })
}

resource "aws_subnet" "public" {
  count                   = var.existing_vpc_id == "" ? 1 : 0
  vpc_id                  = aws_vpc.main[0].id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]

  tags = merge(local.loki_tags, {
    Name = "${var.environment_name}-public"
  })
}

resource "aws_route_table" "public" {
  count  = var.existing_vpc_id == "" ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }

  tags = merge(local.loki_tags, {
    Name = "${var.environment_name}-public-routes"
  })
}

resource "aws_route_table_association" "public" {
  count          = var.existing_vpc_id == "" ? 1 : 0
  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

# ============================================================================
# Security Group
# ============================================================================
resource "aws_security_group" "main" {
  name        = "${var.environment_name}-${var.pack_name}-sg"
  description = "Security group for ${var.environment_name} EC2 instance"
  vpc_id      = local.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
    description = "SSH access"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = merge(local.loki_tags, {
    Name = "${var.environment_name}-sg"
  })
}

# ============================================================================
# IAM Role & Instance Profile
# ============================================================================
resource "aws_iam_role" "instance" {
  name = "${var.environment_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.loki_tags, {
    Name = "${var.environment_name}-role"
  })
}

resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# builder: AdministratorAccess managed policy
resource "aws_iam_role_policy_attachment" "instance_admin" {
  count      = var.profile_name == "builder" ? 1 : 0
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# account_assistant: ReadOnlyAccess managed policy
resource "aws_iam_role_policy_attachment" "instance_readonly" {
  count      = var.profile_name == "account_assistant" ? 1 : 0
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# account_assistant: Bedrock inference (ReadOnlyAccess doesn't include invoke)
resource "aws_iam_role_policy" "account_assistant_bedrock" {
  count  = var.profile_name == "account_assistant" ? 1 : 0
  name   = "${var.environment_name}-bedrock-inference"
  role   = aws_iam_role.instance.id
  policy = file("${path.module}/policies/account_assistant_bedrock.json")
}

# account_assistant: Deny secrets, S3 objects, Lambda code
resource "aws_iam_role_policy" "account_assistant_deny" {
  count  = var.profile_name == "account_assistant" ? 1 : 0
  name   = "${var.environment_name}-deny-secrets-s3"
  role   = aws_iam_role.instance.id
  policy = file("${path.module}/policies/account_assistant_deny.json")
}

# personal_assistant: Bedrock + SSM connectivity only
resource "aws_iam_role_policy" "personal_assistant" {
  count  = var.profile_name == "personal_assistant" ? 1 : 0
  name   = "${var.environment_name}-bedrock-only"
  role   = aws_iam_role.instance.id
  policy = file("${path.module}/policies/personal_assistant.json")
}

# non-builder: scoped bootstrap operations (SSM status + cfn-signal)
# builder has AdministratorAccess which already covers these
resource "aws_iam_role_policy" "bootstrap_operations" {
  count  = var.profile_name != "builder" ? 1 : 0
  name   = "${var.environment_name}-bootstrap-ops"
  role   = aws_iam_role.instance.id
  policy = file("${path.module}/policies/bootstrap_operations.json")
}

resource "aws_iam_instance_profile" "main" {
  name = "${var.environment_name}-profile"
  role = aws_iam_role.instance.name
}

# ============================================================================
# Bedrock Model Access (Lambda + invocation)
# ============================================================================
resource "aws_iam_role" "bedrock_form_lambda" {
  count = var.enable_bedrock_form == "true" ? 1 : 0
  name  = "${var.environment_name}-bedrock-form-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bedrock_form_lambda_basic" {
  count      = var.enable_bedrock_form == "true" ? 1 : 0
  role       = aws_iam_role.bedrock_form_lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "bedrock_form" {
  count = var.enable_bedrock_form == "true" ? 1 : 0
  name  = "bedrock-form"
  role  = aws_iam_role.bedrock_form_lambda[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:PutUseCaseForModelAccess",
          "bedrock:GetUseCaseForModelAccess"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "servicequotas:RequestServiceQuotaIncrease",
          "servicequotas:GetServiceQuota",
          "servicequotas:ListRequestedServiceQuotaChangeHistory"
        ]
        Resource = "*"
      }
    ]
  })
}

data "archive_file" "bedrock_form" {
  count       = var.enable_bedrock_form == "true" ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/.lambda_zips/bedrock_form.zip"

  source {
    content  = <<-PYTHON
import json, time, boto3, traceback

def request_quota_increases():
    sq = boto3.client('servicequotas', region_name='us-east-1')
    quotas = [
        ('L-11DFF789', 1000, 'Cross-region RPM Opus 4.6'),
        ('L-0AD9BBE8', 4000000, 'Cross-region TPM Opus 4.6'),
    ]
    for code, desired, name in quotas:
        try:
            current = sq.get_service_quota(ServiceCode='bedrock', QuotaCode=code)
            current_val = current['Quota']['Value']
            if current_val >= desired:
                print(f"[OK] {name}: already at {current_val}")
                continue
            sq.request_service_quota_increase(
                ServiceCode='bedrock', QuotaCode=code, DesiredValue=desired
            )
            print(f"[OK] {name}: requested {current_val} -> {desired}")
        except Exception as e:
            print(f"[WARN] {name} quota request failed: {e}")

def handler(event, context):
    print(f"[INFO] Event: {json.dumps(event)}")
    request_quotas = event.get('request_quotas', 'false')

    client = boto3.client('bedrock', region_name='us-east-1')
    form_payload = json.dumps({
        "companyName": "My Company",
        "companyWebsite": "https://example.com",
        "intendedUsers": "0",
        "industryOption": "Education",
        "otherIndustryOption": "",
        "useCases": "AI development"
    }).encode()

    try:
        try:
            existing = client.get_use_case_for_model_access()
            print(f"[OK] Form already submitted: {existing.get('formData', '')[:50]}...")
            if request_quotas == 'true':
                request_quota_increases()
            return {'status': 'ALREADY_SUBMITTED'}
        except client.exceptions.ResourceNotFoundException:
            print("[INFO] Form not yet submitted, submitting now...")

        print(f"[INFO] Submitting form ({len(form_payload)} bytes)")
        client.put_use_case_for_model_access(formData=form_payload)
        print("[OK] Form submitted successfully")

        time.sleep(2)
        try:
            verify = client.get_use_case_for_model_access()
            print(f"[OK] Form verified: {verify.get('formData', '')[:50]}...")
        except client.exceptions.ResourceNotFoundException:
            print("[WARN] Form not found after submission")

        if request_quotas == 'true':
            request_quota_increases()

        return {'status': 'SUBMITTED'}
    except Exception as e:
        tb = traceback.format_exc()
        print(f"[FAIL] {e}\n{tb}")
        return {'status': 'FAILED', 'error': str(e)}
    PYTHON
    filename = "index.py"
  }
}

resource "aws_lambda_function" "bedrock_form" {
  count            = var.enable_bedrock_form == "true" ? 1 : 0
  function_name    = "${var.environment_name}-bedrock-form"
  role             = aws_iam_role.bedrock_form_lambda[0].arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 120
  filename         = data.archive_file.bedrock_form[0].output_path
  source_code_hash = data.archive_file.bedrock_form[0].output_base64sha256

  depends_on = [aws_iam_role_policy.bedrock_form]
}

resource "null_resource" "bedrock_form_invoke" {
  count      = var.enable_bedrock_form == "true" ? 1 : 0
  depends_on = [aws_lambda_function.bedrock_form]

  provisioner "local-exec" {
    command = <<-EOT
      aws lambda invoke \
        --function-name "${var.environment_name}-bedrock-form" \
        --payload '${jsonencode({ request_quotas = var.request_quota_increases })}' \
        --cli-binary-format raw-in-base64-out \
        --region ${var.aws_region} \
        /tmp/bedrock_form_response.json && cat /tmp/bedrock_form_response.json
    EOT
  }
}

# ============================================================================
# Security Services Enablement (Lambda + invocation)
# ============================================================================
resource "aws_iam_role" "security_enablement_lambda" {
  name = "${var.environment_name}-security-enable-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "security_enablement_basic" {
  role       = aws_iam_role.security_enablement_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "security_services" {
  name = "security-services"
  role = aws_iam_role.security_enablement_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "securityhub:EnableSecurityHub",
        "securityhub:DescribeHub",
        "securityhub:BatchEnableStandards",
        "guardduty:CreateDetector",
        "guardduty:ListDetectors",
        "inspector2:Enable",
        "inspector2:BatchGetAccountStatus",
        "access-analyzer:CreateAnalyzer",
        "access-analyzer:ListAnalyzers",
        "config:PutConfigurationRecorder",
        "config:PutDeliveryChannel",
        "config:StartConfigurationRecorder",
        "config:DescribeConfigurationRecorders",
        "config:DescribeDeliveryChannels",
        "s3:CreateBucket",
        "s3:PutBucketPolicy",
        "s3:GetBucketPolicy",
        "iam:CreateServiceLinkedRole",
        "iam:GetRole"
      ]
      Resource = "*"
    }]
  })
}

data "archive_file" "security_enablement" {
  type        = "zip"
  output_path = "${path.module}/.lambda_zips/security_enablement.zip"

  source {
    content  = <<-PYTHON
import json, boto3

def handler(event, context):
    print(f"[INFO] Event: {json.dumps(event)}")
    import os
    region = os.environ.get('AWS_REGION', 'us-east-1')
    account_id = boto3.client('sts').get_caller_identity()['Account']
    results = []

    enable_sh = event.get('enable_security_hub', True)
    enable_gd = event.get('enable_guardduty', True)
    enable_insp = event.get('enable_inspector', True)
    enable_aa = event.get('enable_access_analyzer', True)
    enable_cfg = event.get('enable_config_recorder', True)

    # 1. Security Hub
    if enable_sh:
        try:
            sh = boto3.client('securityhub', region_name=region)
            try:
                sh.describe_hub()
                print("[OK] Security Hub already enabled")
            except:
                sh.enable_security_hub(EnableDefaultStandards=True)
                print("[OK] Security Hub enabled")
            results.append('SecurityHub:OK')
        except Exception as e:
            print(f"[WARN] Security Hub: {e}")
            results.append('SecurityHub:WARN')
    else:
        results.append('SecurityHub:SKIPPED')

    # 2. GuardDuty
    if enable_gd:
        try:
            gd = boto3.client('guardduty', region_name=region)
            detectors = gd.list_detectors()['DetectorIds']
            if detectors:
                print(f"[OK] GuardDuty already enabled: {detectors[0]}")
            else:
                resp = gd.create_detector(Enable=True, FindingPublishingFrequency='FIFTEEN_MINUTES')
                print(f"[OK] GuardDuty enabled: {resp['DetectorId']}")
            results.append('GuardDuty:OK')
        except Exception as e:
            print(f"[WARN] GuardDuty: {e}")
            results.append('GuardDuty:WARN')
    else:
        results.append('GuardDuty:SKIPPED')

    # 3. Inspector
    if enable_insp:
        try:
            insp = boto3.client('inspector2', region_name=region)
            insp.enable(resourceTypes=['EC2', 'ECR', 'LAMBDA', 'LAMBDA_CODE'], accountIds=[account_id])
            print("[OK] Inspector enabled (EC2, ECR, Lambda)")
            results.append('Inspector:OK')
        except Exception as e:
            print(f"[WARN] Inspector: {e}")
            results.append('Inspector:WARN')
    else:
        results.append('Inspector:SKIPPED')

    # 4. IAM Access Analyzer
    if enable_aa:
        try:
            aa = boto3.client('accessanalyzer', region_name=region)
            analyzers = aa.list_analyzers(type='ACCOUNT')['analyzers']
            if analyzers:
                print(f"[OK] Access Analyzer already exists: {analyzers[0]['name']}")
            else:
                aa.create_analyzer(analyzerName='account-analyzer', type='ACCOUNT')
                print("[OK] Access Analyzer created")
            results.append('AccessAnalyzer:OK')
        except Exception as e:
            print(f"[WARN] Access Analyzer: {e}")
            results.append('AccessAnalyzer:WARN')
    else:
        results.append('AccessAnalyzer:SKIPPED')

    # 5. Config Recorder
    if enable_cfg:
        try:
            cfg = boto3.client('config', region_name=region)
            recorders = cfg.describe_configuration_recorders()['ConfigurationRecorders']
            if recorders:
                print(f"[OK] Config recorder already exists: {recorders[0]['name']}")
            else:
                s3 = boto3.client('s3', region_name=region)
                bucket_name = f'config-bucket-{account_id}-{region}'
                try:
                    s3.create_bucket(Bucket=bucket_name)
                    s3.put_bucket_policy(Bucket=bucket_name, Policy=json.dumps({
                        'Version': '2012-10-17',
                        'Statement': [{
                            'Sid': 'AWSConfigBucketPermissionsCheck',
                            'Effect': 'Allow',
                            'Principal': {'Service': 'config.amazonaws.com'},
                            'Action': 's3:GetBucketAcl',
                            'Resource': f'arn:aws:s3:::{bucket_name}'
                        }, {
                            'Sid': 'AWSConfigBucketDelivery',
                            'Effect': 'Allow',
                            'Principal': {'Service': 'config.amazonaws.com'},
                            'Action': 's3:PutObject',
                            'Resource': f'arn:aws:s3:::{bucket_name}/*',
                            'Condition': {'StringEquals': {'s3:x-amz-acl': 'bucket-owner-full-control'}}
                        }]
                    }))
                except s3.exceptions.BucketAlreadyOwnedByYou:
                    pass
                except Exception as be:
                    print(f"[WARN] Config bucket: {be}")

                try:
                    cfg.put_configuration_recorder(ConfigurationRecorder={
                        'name': 'default',
                        'roleARN': f'arn:aws:iam::{account_id}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig',
                        'recordingGroup': {'allSupported': True, 'includeGlobalResourceTypes': True}
                    })
                    cfg.put_delivery_channel(DeliveryChannel={
                        'name': 'default',
                        's3BucketName': bucket_name,
                    })
                    cfg.start_configuration_recorder(ConfigurationRecorderName='default')
                    print("[OK] Config recorder started")
                except Exception as ce:
                    print(f"[WARN] Config recorder: {ce}")
            results.append('Config:OK')
        except Exception as e:
            print(f"[WARN] Config: {e}")
            results.append('Config:WARN')
    else:
        results.append('Config:SKIPPED')

    return {'results': ', '.join(results)}
    PYTHON
    filename = "index.py"
  }
}

resource "aws_lambda_function" "security_enablement" {
  function_name    = "${var.environment_name}-security-enable"
  role             = aws_iam_role.security_enablement_lambda.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 120
  filename         = data.archive_file.security_enablement.output_path
  source_code_hash = data.archive_file.security_enablement.output_base64sha256

  depends_on = [aws_iam_role_policy.security_services]
}

resource "null_resource" "security_enablement_invoke" {
  count      = var.profile_name != "personal_assistant" ? 1 : 0
  depends_on = [aws_lambda_function.security_enablement]

  provisioner "local-exec" {
    command = <<-EOT
      aws lambda invoke \
        --function-name "${var.environment_name}-security-enable" \
        --payload '{"enable_security_hub":${var.enable_security_hub},"enable_guardduty":${var.enable_guardduty},"enable_inspector":${var.enable_inspector},"enable_access_analyzer":${var.enable_access_analyzer},"enable_config_recorder":${var.enable_config_recorder}}' \
        --cli-binary-format raw-in-base64-out \
        --region ${var.aws_region} \
        /tmp/security_enable_response.json && cat /tmp/security_enable_response.json
    EOT
  }
}

# ============================================================================
# Admin Console User — only for builder profile
# ============================================================================
resource "aws_iam_user" "admin" {
  count = var.profile_name == "builder" ? 1 : 0
  name  = "${var.environment_name}-admin"

  tags = merge(local.loki_tags, {
    Name      = "${var.environment_name}-admin"
    ManagedBy = "Terraform"
  })
}

resource "aws_iam_user_policy_attachment" "admin" {
  count      = var.profile_name == "builder" ? 1 : 0
  user       = aws_iam_user.admin[0].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_access_key" "admin" {
  count = var.profile_name == "builder" ? 1 : 0
  user  = aws_iam_user.admin[0].name
}

# Admin password Lambda
resource "aws_iam_role" "admin_setup_lambda" {
  count = var.profile_name == "builder" ? 1 : 0
  name  = "${var.environment_name}-admin-pw-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "admin_setup_basic" {
  count      = var.profile_name == "builder" ? 1 : 0
  role       = aws_iam_role.admin_setup_lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "archive_file" "admin_setup" {
  type        = "zip"
  output_path = "${path.module}/.lambda_zips/admin_setup.zip"

  source {
    content  = <<-PYTHON
import json

def handler(event, context):
    # No-op: admin user has API access keys only (no console login)
    print(f"[INFO] Event: {json.dumps(event)}")
    return {'status': 'SUCCESS'}
    PYTHON
    filename = "index.py"
  }
}

resource "aws_lambda_function" "admin_setup" {
  count            = var.profile_name == "builder" ? 1 : 0
  function_name    = "${var.environment_name}-admin-setup"
  role             = aws_iam_role.admin_setup_lambda[0].arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.admin_setup.output_path
  source_code_hash = data.archive_file.admin_setup.output_base64sha256

  depends_on = [aws_iam_role_policy_attachment.admin_setup_basic]
}

resource "null_resource" "admin_setup_invoke" {
  count      = var.profile_name == "builder" ? 1 : 0
  depends_on = [aws_lambda_function.admin_setup, aws_iam_user.admin]

  provisioner "local-exec" {
    command = <<-EOT
      aws lambda invoke \
        --function-name "${var.environment_name}-admin-setup" \
        --payload '${jsonencode({ account_id = data.aws_caller_identity.current.account_id, region = data.aws_region.current.name, admin_username = "${var.environment_name}-admin" })}' \
        --cli-binary-format raw-in-base64-out \
        --region ${var.aws_region} \
        /tmp/admin_setup_response.json && cat /tmp/admin_setup_response.json
    EOT
  }
}

# ============================================================================
# EC2 Instance
# ============================================================================
resource "aws_instance" "main" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  iam_instance_profile   = aws_iam_instance_profile.main.name
  key_name               = var.key_pair_name != "" ? var.key_pair_name : null
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.main.id]
  ebs_optimized          = true

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data_base64 = base64encode(templatefile("${path.module}/userdata.sh.tpl", {
    acct_id          = data.aws_caller_identity.current.account_id
    region           = data.aws_region.current.name
    environment_name = var.environment_name
    pack_name        = var.pack_name
    profile_name     = var.profile_name
    default_model    = var.default_model
    bedrock_region   = var.bedrock_region
    gw_port          = var.openclaw_gateway_port
    model_mode       = var.model_mode
    litellm_base_url = var.litellm_base_url
    litellm_api_key  = var.litellm_api_key
    litellm_model    = var.litellm_model
    provider_api_key = var.provider_api_key
  }))

  tags = merge(local.loki_tags, {
    Name        = "${var.environment_name}-instance"
    Application = "OpenClaw"
  })

  depends_on = [
    aws_internet_gateway.main,
    null_resource.bedrock_form_invoke,
  ]
}

resource "aws_ebs_volume" "data" {
  count             = var.data_volume_size > 0 ? 1 : 0
  availability_zone = data.aws_availability_zones.available.names[0]
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = merge(local.loki_tags, {
    Name = "${var.environment_name}-data"
  })
}

resource "aws_volume_attachment" "data" {
  count       = var.data_volume_size > 0 ? 1 : 0
  device_name = "/dev/sdb"
  volume_id   = aws_ebs_volume.data[0].id
  instance_id = aws_instance.main.id
}
