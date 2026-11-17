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

  # Value the A record holds while the server is down (see lambda/dns_reset.py).
  dns_placeholder_ip = "127.0.0.1"
  dns_record_ttl     = 30

  # Effective VPC/subnets: created here, or caller-supplied when create_vpc = false.
  vpc_id     = var.create_vpc ? one(aws_vpc.this[*].id) : var.vpc_id
  subnet_ids = var.create_vpc ? aws_subnet.public[*].id : var.subnet_ids

  # Server edition drives the primary game port protocol and the default image.
  # Java listens on TCP 25565; native Bedrock listens on UDP 19132.
  is_bedrock    = var.server_edition == "bedrock"
  game_protocol = local.is_bedrock ? "udp" : "tcp"
  game_port     = local.is_bedrock ? 19132 : var.minecraft_port

  tags = merge(
    {
      Name      = local.name
      ManagedBy = "terraform"
      Module    = "terraform-aws-minecraft"
    },
    var.tags,
  )
}
