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

  # Effective VPC/subnets: created here, or caller-supplied when create_vpc = false.
  vpc_id     = var.create_vpc ? one(aws_vpc.this[*].id) : var.vpc_id
  subnet_ids = var.create_vpc ? aws_subnet.public[*].id : var.subnet_ids

  # Server edition drives the primary game port protocol and the default image.
  # Java listens on TCP 25565; native Bedrock listens on UDP 19132.
  is_bedrock    = var.server_edition == "bedrock"
  game_protocol = local.is_bedrock ? "udp" : "tcp"
  game_port     = local.is_bedrock ? 19132 : var.minecraft_port

  container_image = var.minecraft_image != "" ? var.minecraft_image : (
    local.is_bedrock ? "itzg/minecraft-bedrock-server:latest" : "itzg/minecraft-server:latest"
  )

  # itzg/minecraft-server environment. EULA + heap size are always set; anything
  # in var.minecraft_env overrides/extends them (e.g. TYPE, VERSION, CF_API_KEY).
  minecraft_environment = merge(
    {
      EULA   = "TRUE"
      MEMORY = var.java_memory
    },
    var.minecraft_env,
  )

  # Cartesian product of additional_ports x allowed_cidrs, keyed stably so the
  # security-group for_each stays deterministic across plans.
  additional_port_rules = {
    for pair in setproduct(var.additional_ports, var.allowed_cidrs) :
    "${pair[0].protocol}-${pair[0].port}-${pair[1]}" => {
      port     = pair[0].port
      protocol = pair[0].protocol
      cidr     = pair[1]
    }
  }

  tags = merge(
    {
      Name      = local.name
      ManagedBy = "terraform"
      Module    = "terraform-aws-minecraft"
    },
    var.tags,
  )
}
