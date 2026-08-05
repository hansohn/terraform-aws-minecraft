################################################################################
# DNS reset Lambda
#
# The watchdog points the A record at the running task but never cleans up, so
# a stopped server would keep resolving to a public IP AWS has since handed to
# someone else. An EventBridge rule on the service's task-stopped events parks
# the record back on the placeholder. Runs in the compute region alongside the
# cluster emitting the events (Route53 itself is global).
################################################################################

data "archive_file" "dns_reset" {
  type        = "zip"
  source_file = "${path.module}/lambda/dns_reset.py"
  output_path = "${path.module}/lambda/dns_reset.zip"
}

resource "aws_cloudwatch_log_group" "dns_reset" {
  name              = "/aws/lambda/${local.name}-dns-reset"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_iam_role" "dns_reset" {
  name_prefix        = "${local.name}-dns-reset-"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "dns_reset" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }

  # Same cycle as the task role's ScaleSelf statement (service -> task def ->
  # ... -> service), so the service ARN can't be referenced here.
  statement {
    sid       = "CheckDesiredCount"
    actions   = ["ecs:DescribeServices"]
    resources = ["*"]
  }

  statement {
    sid       = "ResetDns"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [aws_route53_zone.this.arn]
  }
}

resource "aws_iam_role_policy" "dns_reset" {
  name_prefix = "${local.name}-dns-reset-"
  role        = aws_iam_role.dns_reset.id
  policy      = data.aws_iam_policy_document.dns_reset.json
}

resource "aws_lambda_function" "dns_reset" {
  function_name    = "${local.name}-dns-reset"
  role             = aws_iam_role.dns_reset.arn
  runtime          = "python3.12"
  handler          = "dns_reset.handler"
  filename         = data.archive_file.dns_reset.output_path
  source_code_hash = data.archive_file.dns_reset.output_base64sha256
  timeout          = 30
  tags             = local.tags

  environment {
    variables = {
      CLUSTER        = aws_ecs_cluster.this.name
      SERVICE        = aws_ecs_service.this.name
      ZONE_ID        = aws_route53_zone.this.zone_id
      DOMAIN_NAME    = var.domain_name
      PLACEHOLDER_IP = local.dns_placeholder_ip
      RECORD_TTL     = tostring(local.dns_record_ttl)
    }
  }

  depends_on = [aws_cloudwatch_log_group.dns_reset]
}

# Service-managed tasks carry group "service:<name>", which keeps the rule from
# firing on one-off tasks (e.g. an ECS Exec debug run) in the same cluster.
resource "aws_cloudwatch_event_rule" "task_stopped" {
  name        = "${local.name}-task-stopped"
  description = "Fires when a ${local.name} service task stops"
  tags        = local.tags

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Task State Change"]
    detail = {
      clusterArn = [aws_ecs_cluster.this.arn]
      group      = ["service:${aws_ecs_service.this.name}"]
      lastStatus = ["STOPPED"]
    }
  })
}

resource "aws_cloudwatch_event_target" "dns_reset" {
  rule      = aws_cloudwatch_event_rule.task_stopped.name
  target_id = "dns-reset"
  arn       = aws_lambda_function.dns_reset.arn
}

resource "aws_lambda_permission" "dns_reset" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dns_reset.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.task_stopped.arn
}
