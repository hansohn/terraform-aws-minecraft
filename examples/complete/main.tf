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

  # Deploy into an existing VPC instead of creating one. Subnets must be
  # PUBLIC (route to an IGW) and in distinct AZs. Default creates a VPC.
  # create_vpc = false
  # vpc_id     = "vpc-0123456789abcdef0"
  # subnet_ids = ["subnet-aaa", "subnet-bbb"]

  # Point-in-time EFS backups (opt-in); enable and optionally tune retention.
  enable_backups        = true
  backup_retention_days = 14

  # Notifications: email via SNS, and/or repost to Discord (pass as a secret).
  notification_email  = var.notification_email
  discord_webhook_url = var.discord_webhook_url

  # Publish a /minecraft slash command so players can wake the server from
  # Discord and see that it's starting. Register the command and paste the
  # discord_interactions_url output into the Developer Portal — see the module
  # README. Pairs with discord_webhook_url, which announces when it's ready.
  discord_application_public_key = var.discord_application_public_key
  discord_guild_id               = var.discord_guild_id

  # Only this Discord role may run start/stop and change the gate. Left empty,
  # guild membership alone is enough — which is the pre-0.8.0 behaviour.
  discord_privileged_role_id = var.discord_privileged_role_id

  # Hours during which a DNS lookup may wake the server. Outside them the name
  # still resolves but nothing starts, which is what keeps scanners — and
  # after-hours players — from booting the task. Empty list = no restriction.
  wake_default_mode = "schedule"
  wake_timezone     = "America/Los_Angeles"
  wake_windows = [
    { days = ["mon", "tue", "wed", "thu"], start = "15:30", end = "20:30" },
    { days = ["fri"], start = "15:30", end = "22:00" },
    { days = ["sat", "sun"], start = "09:00", end = "22:00" },
  ]

  # Also stop a server that is ALREADY RUNNING when its window closes, warning
  # players in-game first. Off by default because it disconnects them mid-game.
  enable_curfew          = true
  curfew_warning_minutes = 10

  tags = {
    Environment = "personal"
  }
}
