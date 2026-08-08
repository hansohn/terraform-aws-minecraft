################################################################################
# Outputs
################################################################################

output "name_servers" {
  description = "Route53 name servers for the delegated zone. Create NS records for this subdomain at your parent-domain DNS provider (Cloudflare), DNS-only / unproxied."
  value       = aws_route53_zone.this.name_servers
}

output "server_address" {
  description = "Hostname players connect to."
  value       = var.domain_name
}

output "hosted_zone_id" {
  description = "Route53 hosted zone ID."
  value       = aws_route53_zone.this.zone_id
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.this.name
}

output "efs_id" {
  description = "EFS file system ID holding the world data."
  value       = aws_efs_file_system.this.id
}

output "sns_topic_arn" {
  description = "SNS topic ARN for start/stop notifications."
  value       = aws_sns_topic.this.arn
}

output "discord_interactions_url" {
  description = "Lambda Function URL to paste into the Discord Developer Portal as the app's Interactions Endpoint URL. Empty unless discord_application_public_key is set."
  value       = try(aws_lambda_function_url.discord_command[0].function_url, "")
}

output "vpc_id" {
  description = "VPC ID hosting the server (created or caller-supplied)."
  value       = local.vpc_id
}

output "controller_function_name" {
  description = "Lambda that owns starting and stopping the service — the only role holding ecs:UpdateService. Start the server without Discord or a DNS query: aws lambda invoke --function-name <this> --payload '{\"action\":\"start\",\"source\":\"cli\"}' /dev/stdout. The gate still applies to this path, so a start while the mode is \"disable\" is refused; change the gate first via gate_parameter_name."
  value       = aws_lambda_function.controller.function_name
}

output "gate_parameter_name" {
  description = "SSM parameter holding the runtime wake-gate state. Change the mode without Discord: aws ssm put-parameter --name <this> --overwrite --value '{\"version\":1,\"mode\":\"disable\"}'."
  value       = aws_ssm_parameter.gate.name
}
