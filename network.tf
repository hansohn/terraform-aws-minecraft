################################################################################
# Network
#
# A minimal public-subnet VPC. The task gets a public IP and connects directly
# to the internet gateway — no NAT gateway (which would cost far more than the
# server itself).
################################################################################

# VPC/subnets/routing are created only when create_vpc = true. Otherwise the
# task and EFS attach to caller-supplied vpc_id / subnet_ids (see locals).
resource "aws_vpc" "this" {
  count                = var.create_vpc ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = local.name })
}

resource "aws_internet_gateway" "this" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  tags   = merge(local.tags, { Name = local.name })
}

resource "aws_subnet" "public" {
  count                   = var.create_vpc ? length(local.azs) : 0
  vpc_id                  = aws_vpc.this[0].id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 2, count.index)
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "${local.name}-public-${local.azs[count.index]}" })
}

resource "aws_route_table" "public" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }

  tags = merge(local.tags, { Name = "${local.name}-public" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

# Security group for the game server task.
resource "aws_security_group" "server" {
  name_prefix = "${local.name}-server-"
  description = "Minecraft server task"
  vpc_id      = local.vpc_id
  tags        = merge(local.tags, { Name = "${local.name}-server" })

  lifecycle {
    create_before_destroy = true
  }
}

# Primary game port. One rule per allowed CIDR (default 0.0.0.0/0 = open).
# Protocol/port follow the edition: TCP 25565 for java, UDP 19132 for bedrock.
resource "aws_vpc_security_group_ingress_rule" "server_game" {
  for_each          = toset(var.allowed_cidrs)
  security_group_id = aws_security_group.server.id
  description       = "Minecraft ${var.server_edition}"
  from_port         = local.game_port
  to_port           = local.game_port
  ip_protocol       = local.game_protocol
  cidr_ipv4         = each.value
}

# Extra UDP port for Bedrock clients via the Geyser plugin (java servers only).
resource "aws_vpc_security_group_ingress_rule" "server_bedrock" {
  for_each          = var.enable_geyser && !local.is_bedrock ? toset(var.allowed_cidrs) : toset([])
  security_group_id = aws_security_group.server.id
  description       = "Geyser / Bedrock"
  from_port         = var.bedrock_port
  to_port           = var.bedrock_port
  ip_protocol       = "udp"
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "server_all" {
  security_group_id = aws_security_group.server.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
