################################################################################
# Provider
################################################################################

variable "region" {
  type        = string
  default     = "us-west-2"
  description = "AWS region for the server (compute). The Route53 query-logging resources are always created in us-east-1."
}

################################################################################
# Variables
################################################################################

variable "domain_name" {
  type        = string
  default     = "minecraft.hansohn.io"
  description = "Server hostname / delegated Route53 zone name."
}

variable "notification_email" {
  type        = string
  default     = ""
  description = "Optional email for start/stop notifications."
}

variable "discord_webhook_url" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional Discord webhook for start/stop notifications. Pass via TF_VAR_discord_webhook_url; do not commit it."
}

variable "discord_application_public_key" {
  type        = string
  default     = ""
  description = "Optional Discord application public key. When set, publishes a /minecraft slash command that wakes the server and reports status."
}

variable "discord_guild_id" {
  type        = string
  default     = ""
  description = "Optional Discord server (guild) ID to restrict the /minecraft slash command to."
}

variable "discord_privileged_role_id" {
  type        = string
  default     = ""
  description = "Optional Discord role ID allowed to run start/stop and change the wake gate. Empty means any guild member may."
}
