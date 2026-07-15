################################################################################
# Discord notifications
#
# Optional: repost SNS start/stop notifications to a Discord channel webhook.
# The stock watchdog only speaks SNS/Twilio, so a small Lambda subscribes to the
# existing SNS topic and forwards each message to the webhook. Enabled only when
# discord_webhook_url is set.
################################################################################

locals {
  discord_enabled = var.discord_webhook_url != ""
}

data "archive_file" "discord" {
  count       = local.discord_enabled ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/discord.py"
  output_path = "${path.module}/lambda/discord.zip"
}

resource "aws_cloudwatch_log_group" "discord" {
  count             = local.discord_enabled ? 1 : 0
  name              = "/aws/lambda/${local.name}-discord"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

data "aws_iam_policy_document" "discord_assume" {
  count = local.discord_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "discord" {
  count              = local.discord_enabled ? 1 : 0
  name_prefix        = "${local.name}-discord-"
  assume_role_policy = data.aws_iam_policy_document.discord_assume[0].json
  tags               = local.tags
}

data "aws_iam_policy_document" "discord" {
  count = local.discord_enabled ? 1 : 0

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_role_policy" "discord" {
  count       = local.discord_enabled ? 1 : 0
  name_prefix = "${local.name}-discord-"
  role        = aws_iam_role.discord[0].id
  policy      = data.aws_iam_policy_document.discord[0].json
}

resource "aws_lambda_function" "discord" {
  count            = local.discord_enabled ? 1 : 0
  function_name    = "${local.name}-discord"
  role             = aws_iam_role.discord[0].arn
  runtime          = "python3.12"
  handler          = "discord.handler"
  filename         = data.archive_file.discord[0].output_path
  source_code_hash = data.archive_file.discord[0].output_base64sha256
  timeout          = 10
  tags             = local.tags

  environment {
    variables = {
      DISCORD_WEBHOOK_URL = var.discord_webhook_url
    }
  }

  depends_on = [aws_cloudwatch_log_group.discord]
}

resource "aws_lambda_permission" "discord_sns" {
  count         = local.discord_enabled ? 1 : 0
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.discord[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.this.arn
}

resource "aws_sns_topic_subscription" "discord" {
  count     = local.discord_enabled ? 1 : 0
  topic_arn = aws_sns_topic.this.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.discord[0].arn

  depends_on = [aws_lambda_permission.discord_sns]
}
