################################################################################
# SNS notifications (server start / stop)
################################################################################

resource "aws_sns_topic" "this" {
  name_prefix = "${local.name}-"
  # Server-side encryption with the AWS-managed SNS key (no extra cost).
  kms_master_key_id = "alias/aws/sns"
  tags              = local.tags
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.this.arn
  protocol  = "email"
  endpoint  = var.notification_email
}
