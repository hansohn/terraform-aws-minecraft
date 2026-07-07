################################################################################
# SNS notifications (server start / stop)
################################################################################

resource "aws_sns_topic" "this" {
  name_prefix = "${local.name}-"
  tags        = local.tags
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.this.arn
  protocol  = "email"
  endpoint  = var.notification_email
}
