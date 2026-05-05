# Terraform Deployment

Deploy Loki using Terraform.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- AWS credentials configured (`aws configure` or environment variables)

## Quick Start

```bash
terraform init
terraform plan -var="environment_name=my-openclaw"
terraform apply -var="environment_name=my-openclaw" -var="profile_name=builder"
```

## Variables

Override defaults with `-var` flags or a `terraform.tfvars` file:

```hcl
# terraform.tfvars
environment_name   = "my-openclaw"
instance_type      = "t4g.xlarge"
profile_name       = "builder"
model_mode         = "bedrock"
bedrock_region     = "us-east-1"

# Security services (all default true — set false for test deploys)
enable_security_hub    = true
enable_guardduty       = true
enable_inspector       = true
enable_access_analyzer = true
enable_config_recorder = true

# Watermark tag
loki_watermark = "my-team"
```

## What's Different from CloudFormation?

- Lambda custom resources are deployed as `aws_lambda_function` and invoked via `null_resource` + `local-exec` (no CloudFormation custom resource wrapper)
- EC2 UserData is templated via `userdata.sh.tpl` using Terraform's `templatefile()` function
- Data volume is a separate `aws_ebs_volume` + `aws_volume_attachment`

## Files

| File | Description |
|------|-------------|
| `main.tf` | All resources |
| `variables.tf` | Input variables with defaults |
| `outputs.tf` | Stack outputs |
| `providers.tf` | AWS provider configuration |
| `userdata.sh.tpl` | EC2 UserData template |

## Tear Down

```bash
terraform destroy -var="environment_name=my-openclaw"
```

## Notes

- `terraform apply` takes ~8–10 minutes (EC2 bootstrap runs in the background)
- Terraform won't wait for the bootstrap to finish — the instance will be "running" before Loki setup completes
- Check progress: `aws ssm get-parameter --name /openclaw/setup-status --query Parameter.Value --output text`

## Next Steps

See [Next Steps After Deployment](../README.md#next-steps-after-deployment) for bootstrap scripts setup.
