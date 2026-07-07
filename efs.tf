################################################################################
# EFS
#
# Persistent world storage that survives task shutdowns. Cheap at rest and
# transitions cold data to Infrequent Access automatically.
################################################################################

resource "aws_security_group" "efs" {
  name_prefix = "${local.name}-efs-"
  description = "EFS mount targets for Minecraft"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${local.name}-efs" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "efs_nfs" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS from server task"
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.server.id
}

resource "aws_efs_file_system" "this" {
  creation_token  = local.name
  encrypted       = true
  throughput_mode = var.efs_throughput_mode
  tags            = merge(local.tags, { Name = local.name })

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
}

resource "aws_efs_mount_target" "this" {
  count           = length(aws_subnet.public)
  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = aws_subnet.public[count.index].id
  security_groups = [aws_security_group.efs.id]
}

# Access point pins ownership to uid/gid 1000, which is what itzg/minecraft-server
# runs as, so the world directory is writable without extra chown steps.
resource "aws_efs_access_point" "this" {
  file_system_id = aws_efs_file_system.this.id
  tags           = merge(local.tags, { Name = local.name })

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = "/minecraft"

    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }
}
