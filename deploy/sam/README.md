# SAM Deployment

Deploy Loki using the AWS Serverless Application Model (SAM) CLI.

## Prerequisites

- [SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html) installed

## Quick Start

```bash
sam deploy \
  --template-file template.yaml \
  --stack-name my-openclaw \
  --region us-east-1 \
  --parameter-overrides \
    EnvironmentName=my-openclaw \
    InstanceType=t4g.xlarge \
    ModelMode=bedrock \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --no-confirm-changeset
```

Or use guided mode for interactive parameter input:

```bash
sam deploy --guided --template-file template.yaml
```

## What's Different from CloudFormation?

The SAM template uses `Transform: AWS::Serverless-2016-10-31` and `AWS::Serverless::Function` for the Lambda custom resources. This means:

- SAM auto-generates IAM execution roles for Lambda functions (using `Policies` instead of separate `AWS::IAM::Role` resources)
- Requires `CAPABILITY_AUTO_EXPAND` in addition to `CAPABILITY_NAMED_IAM`
- Otherwise identical infrastructure and parameters

## Outputs

Same as the CloudFormation template — `InstanceId`, `PublicIp`, `SSMConnect`, `RoleArn`, `VpcId`.

## Notes

- No S3 bucket required — all Lambda code is inline (`InlineCode`)
- Stack creation takes ~8–10 minutes
- Use `sam delete --stack-name my-openclaw` to tear down
