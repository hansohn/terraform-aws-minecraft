################################################################################
# Backups (AWS Backup)
#
# Optional point-in-time backups of the EFS world data. EFS is durable but has
# no restore points on its own; these protect against world corruption,
# griefing, a bad plugin/mod update, or accidental deletion. Billed per GB of
# backup retained (a small world is cents/month).
################################################################################

resource "aws_backup_vault" "this" {
  count = var.enable_backups ? 1 : 0
  name  = local.name
  tags  = local.tags
}

resource "aws_backup_plan" "this" {
  count = var.enable_backups ? 1 : 0
  name  = local.name
  tags  = local.tags

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this[0].name
    schedule          = var.backup_schedule

    lifecycle {
      delete_after = var.backup_retention_days
    }
  }
}

# Service role AWS Backup assumes to snapshot and restore the EFS filesystem.
data "aws_iam_policy_document" "backup_assume" {
  count = var.enable_backups ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  count              = var.enable_backups ? 1 : 0
  name_prefix        = "${local.name}-backup-"
  assume_role_policy = data.aws_iam_policy_document.backup_assume[0].json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  count      = var.enable_backups ? 1 : 0
  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_selection" "this" {
  count        = var.enable_backups ? 1 : 0
  name         = local.name
  plan_id      = aws_backup_plan.this[0].id
  iam_role_arn = aws_iam_role.backup[0].arn
  resources    = [aws_efs_file_system.this.arn]
}
