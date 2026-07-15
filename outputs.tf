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

output "vpc_id" {
  description = "VPC ID hosting the server (created or caller-supplied)."
  value       = local.vpc_id
}
