################################################################################
# DNS wake relay (us-east-1: must match the query log group's region)
#
# A CloudWatch Logs subscription filter on the Route53 query log fires this
# function whenever someone resolves the server hostname. It forwards a start
# request to the controller and stops there — it holds no ECS permissions and
# cannot start anything itself. Whether the request is honoured is the gate's
# decision (see controller.tf).
#
# Optional (enable_dns_wake, default true). Waking on a DNS query is
# unauthenticated by construction: the filter matches every event and the relay
# inspects none of it, so automated DNS scanners reach the controller as readily
# as players do. That is survivable now that the controller decides, but set
# enable_dns_wake = false to remove the path entirely and drive starts from the
# signature-verified Discord command instead.
#
# Route53 query logging (dns.tf) stays on either way — it is the only record of
# who is resolving the hostname, and it is what makes an unexpected start
# attributable after the fact.
################################################################################

locals {
  dns_wake_enabled = var.enable_dns_wake
}

data "archive_file" "launcher" {
  count       = local.dns_wake_enabled ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/launcher.py"
  output_path = "${path.module}/lambda/launcher.zip"
}

resource "aws_cloudwatch_log_group" "launcher" {
  count             = local.dns_wake_enabled ? 1 : 0
  provider          = aws.us_east_1
  name              = "/aws/lambda/${local.name}-launcher"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_lambda_function" "launcher" {
  count            = local.dns_wake_enabled ? 1 : 0
  provider         = aws.us_east_1
  function_name    = "${local.name}-launcher"
  role             = aws_iam_role.launcher[0].arn
  runtime          = "python3.12"
  handler          = "launcher.handler"
  filename         = data.archive_file.launcher[0].output_path
  source_code_hash = data.archive_file.launcher[0].output_base64sha256
  timeout          = 10
  tags             = local.tags

  environment {
    variables = {
      # The controller lives in the compute region; boto3 cannot infer that from
      # the ARN, so the client is pinned explicitly.
      REGION         = local.region
      CONTROLLER_ARN = local.controller_arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.launcher]
}

resource "aws_lambda_permission" "querylog" {
  count         = local.dns_wake_enabled ? 1 : 0
  provider      = aws.us_east_1
  statement_id  = "AllowExecutionFromCloudWatchLogs"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.launcher[0].function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.querylog.arn}:*"
}

resource "aws_cloudwatch_log_subscription_filter" "querylog" {
  count           = local.dns_wake_enabled ? 1 : 0
  provider        = aws.us_east_1
  name            = "${local.name}-launcher"
  log_group_name  = aws_cloudwatch_log_group.querylog.name
  filter_pattern  = ""
  destination_arn = aws_lambda_function.launcher[0].arn

  depends_on = [aws_lambda_permission.querylog]
}

resource "aws_iam_role" "launcher" {
  count              = local.dns_wake_enabled ? 1 : 0
  name_prefix        = "${local.name}-launcher-"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "launcher" {
  count       = local.dns_wake_enabled ? 1 : 0
  name_prefix = "${local.name}-launcher-"
  role        = aws_iam_role.launcher[0].id
  policy      = data.aws_iam_policy_document.invoke_controller.json
}
