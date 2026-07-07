################################################################################
# Main
################################################################################

# Compute provider — where the server actually runs (close to the players). The
# module manages its own us-east-1 provider internally for DNS query logging.
provider "aws" {
  region = var.region
}

module "minecraft" {
  source = "../../"

  domain_name = var.domain_name

  # Modded server for ~4-5 players on Fargate Spot.
  task_cpu    = 2048
  task_memory = 16384
  java_memory = "10G"
  use_spot    = true

  # Configure the modpack via itzg/minecraft-server env vars. Example using
  # CurseForge auto-install (needs a free CF_API_KEY):
  #
  # minecraft_env = {
  #   TYPE           = "AUTO_CURSEFORGE"
  #   CF_API_KEY     = "your-curseforge-api-key"
  #   CF_SLUG        = "all-the-mods-9"
  #   ALLOW_FLIGHT   = "TRUE"
  # }

  notification_email = var.notification_email

  tags = {
    Environment = "personal"
  }
}
