################################################################################
# Network
#
# A minimal public-subnet VPC. The task gets a public IP and connects directly
# to the internet gateway — no NAT gateway (which would cost far more than the
# server itself).
################################################################################

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = local.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = local.name })
}

resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 2, count.index)
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "${local.name}-public-${local.azs[count.index]}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.tags, { Name = "${local.name}-public" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Security group for the game server task.
resource "aws_security_group" "server" {
  name_prefix = "${local.name}-server-"
  description = "Minecraft server task"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${local.name}-server" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "server_game" {
  security_group_id = aws_security_group.server.id
  description       = "Minecraft Java"
  from_port         = var.minecraft_port
  to_port           = var.minecraft_port
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "server_all" {
  security_group_id = aws_security_group.server.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
