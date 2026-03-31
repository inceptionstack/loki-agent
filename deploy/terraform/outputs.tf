output "instance_id" {
  description = "EC2 Instance ID"
  value       = aws_instance.main.id
}

output "public_ip" {
  description = "Public IP address"
  value       = aws_instance.main.public_ip
}

output "private_ip" {
  description = "Private IP address"
  value       = aws_instance.main.private_ip
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "security_group_id" {
  description = "Security Group ID"
  value       = aws_security_group.main.id
}

output "role_arn" {
  description = "IAM Role ARN"
  value       = aws_iam_role.instance.arn
}

output "ssm_connect" {
  description = "Connect via SSM Session Manager"
  value       = "aws ssm start-session --target ${aws_instance.main.id} --region ${data.aws_region.current.name}"
}

output "pack_name" {
  description = "Deployed agent pack"
  value       = var.pack_name
}
