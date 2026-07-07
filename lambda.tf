################################################################################
# Launcher Lambda (us-east-1: must match the query log group's region)
#
# A CloudWatch Logs subscription filter on the Route53 query log fires this
# function whenever someone resolves the server hostname. It sets the ECS
# service desired count to 1 (a cross-region call to the compute region). The
# watchdog sidecar scales it back to 0 once the server is idle.
################################################################################

data "archive_file" "launcher" {
  type        = "zip"
  source_file = "${path.module}/lambda/launcher.py"
  output_path = "${path.module}/lambda/launcher.zip"
}

resource "aws_cloudwatch_log_group" "launcher" {
  provider          = aws.us_east_1
  name              = "/aws/lambda/${local.name}-launcher"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_lambda_function" "launcher" {
  provider         = aws.us_east_1
  function_name    = "${local.name}-launcher"
  role             = aws_iam_role.launcher.arn
  runtime          = "python3.12"
  handler          = "launcher.handler"
  filename         = data.archive_file.launcher.output_path
  source_code_hash = data.archive_file.launcher.output_base64sha256
  timeout          = 30
  tags             = local.tags

  environment {
    variables = {
      REGION  = data.aws_region.current.name
      CLUSTER = aws_ecs_cluster.this.name
      SERVICE = aws_ecs_service.this.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.launcher]
}

resource "aws_lambda_permission" "querylog" {
  provider      = aws.us_east_1
  statement_id  = "AllowExecutionFromCloudWatchLogs"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.launcher.function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.querylog.arn}:*"
}

resource "aws_cloudwatch_log_subscription_filter" "querylog" {
  provider        = aws.us_east_1
  name            = "${local.name}-launcher"
  log_group_name  = aws_cloudwatch_log_group.querylog.name
  filter_pattern  = ""
  destination_arn = aws_lambda_function.launcher.arn

  depends_on = [aws_lambda_permission.querylog]
}
