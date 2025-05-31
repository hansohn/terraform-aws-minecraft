#--------------------------------------------------------------
# Provider
#--------------------------------------------------------------

variable "region" {
  type        = string
  default     = null
  description = "If specified, the AWS region this bucket should reside in. Otherwise, the region used by the callee"
}

#--------------------------------------------------------------
# Variables
#--------------------------------------------------------------

