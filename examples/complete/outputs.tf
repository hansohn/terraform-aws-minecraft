################################################################################
# Outputs
################################################################################

output "name_servers" {
  description = "Add these as NS records for the subdomain at your parent-domain DNS (Cloudflare), DNS-only."
  value       = module.minecraft.name_servers
}

output "server_address" {
  description = "Hostname players connect to."
  value       = module.minecraft.server_address
}
