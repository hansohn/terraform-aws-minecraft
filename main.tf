################################################################################
# Main
################################################################################

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = var.name

  # Compute region — where the ECS service runs. Used for the awslogs driver and
  # passed to the us-east-1 launcher Lambda so it targets the right region.
  region = data.aws_region.current.region

  # Two AZs for EFS mount-target redundancy; the task itself runs in one.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # itzg/minecraft-server environment. EULA + heap size are always set; anything
  # in var.minecraft_env overrides/extends them (e.g. TYPE, VERSION, CF_API_KEY).
  minecraft_environment = merge(
    {
      EULA   = "TRUE"
      MEMORY = var.java_memory
    },
    var.minecraft_env,
  )

  tags = merge(
    {
      Name      = local.name
      ManagedBy = "terraform"
      Module    = "terraform-aws-minecraft"
    },
    var.tags,
  )
}
