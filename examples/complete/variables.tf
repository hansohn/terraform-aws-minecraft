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
