################################################################################
# Terraform and provider version constraints
################################################################################

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
    # Only instantiated when enable_curfew is true, for the RCON password the
    # server and the announcer sidecar share.
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}
