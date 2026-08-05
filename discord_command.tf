################################################################################
# Discord slash command
#
# Optional: a /minecraft command that wakes the server and reports status, so
# players get an immediate answer instead of retrying a hostname that resolves
# to a placeholder while the task boots. Enabled only when
# discord_application_public_key is set.
#
# The handler is exposed through a Lambda Function URL because Discord posts
# interactions to a plain HTTPS endpoint. Auth is NONE — Discord cannot sign
# with SigV4 — so the function's Ed25519 signature check is the access control;
# see lambda/discord_command.py.
################################################################################

locals {
  discord_command_enabled = var.discord_application_public_key != ""
}

data "archive_file" "discord_command" {
  count       = local.discord_command_enabled ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/discord_command.py"
  output_path = "${path.module}/lambda/discord_command.zip"
}

resource "aws_cloudwatch_log_group" "discord_command" {
  count             = local.discord_command_enabled ? 1 : 0
  name              = "/aws/lambda/${local.name}-discord-command"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_iam_role" "discord_command" {
  count              = local.discord_command_enabled ? 1 : 0
  name_prefix        = "${local.name}-discord-command-"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "discord_command" {
  count = local.discord_command_enabled ? 1 : 0

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }

  # Same dependency cycle as the task role's ScaleSelf statement (service ->
  # task def -> ... -> service), so the service ARN can't be referenced here.
  statement {
    sid       = "StartServer"
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "discord_command" {
  count       = local.discord_command_enabled ? 1 : 0
  name_prefix = "${local.name}-discord-command-"
  role        = aws_iam_role.discord_command[0].id
  policy      = data.aws_iam_policy_document.discord_command[0].json
}

resource "aws_lambda_function" "discord_command" {
  count            = local.discord_command_enabled ? 1 : 0
  function_name    = "${local.name}-discord-command"
  role             = aws_iam_role.discord_command[0].arn
  runtime          = "python3.12"
  handler          = "discord_command.handler"
  filename         = data.archive_file.discord_command[0].output_path
  source_code_hash = data.archive_file.discord_command[0].output_base64sha256
  timeout          = 10
  tags             = local.tags

  environment {
    variables = {
      DISCORD_PUBLIC_KEY = var.discord_application_public_key
      CLUSTER            = aws_ecs_cluster.this.name
      SERVICE            = aws_ecs_service.this.name
      DOMAIN_NAME        = var.domain_name
      DISCORD_GUILD_ID   = var.discord_guild_id
    }
  }

  depends_on = [aws_cloudwatch_log_group.discord_command]
}

resource "aws_lambda_function_url" "discord_command" {
  count              = local.discord_command_enabled ? 1 : 0
  function_name      = aws_lambda_function.discord_command[0].function_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "discord_command_url" {
  count                  = local.discord_command_enabled ? 1 : 0
  statement_id           = "AllowDiscordInteractions"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.discord_command[0].function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}
