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

  # Paper server for ~4-5 players on Fargate Spot.
  task_cpu    = 2048
  task_memory = 16384
  java_memory = "10G"
  use_spot    = true

  # Paper + Geyser/Floodgate so Bedrock clients can join the Java world
  # (opens UDP 19132). itzg auto-installs the plugins from Modrinth.
  enable_geyser = true
  minecraft_env = {
    TYPE              = "PAPER"
    MODRINTH_PROJECTS = "geyser,floodgate"
  }

  # ...or run a native Bedrock server instead of Java (UDP 19132):
  # server_edition = "bedrock"

  # Configure a modpack instead via itzg env vars, e.g. CurseForge auto-install:
  # minecraft_env = {
  #   TYPE       = "AUTO_CURSEFORGE"
  #   CF_API_KEY = "your-curseforge-api-key"
  #   CF_SLUG    = "all-the-mods-9"
  # }

  # Restrict who can connect (default is open to the internet).
  # allowed_cidrs = ["203.0.113.4/32"]

  # Point-in-time EFS backups (opt-in); enable and optionally tune retention.
  enable_backups        = true
  backup_retention_days = 14

  # Notifications: email via SNS, and/or repost to Discord (pass as a secret).
  notification_email  = var.notification_email
  discord_webhook_url = var.discord_webhook_url

  tags = {
    Environment = "personal"
  }
}
