################################################################################
# Controller Lambda — the only thing that may start or stop the service
#
# Every wake path funnels through here: the us-east-1 relay (launcher.tf), the
# Discord slash command (discord_command.tf), and the curfew schedules
# (curfew.tf). Those callers get lambda:InvokeFunction on this function and
# nothing else, so this role is the SOLE holder of ecs:UpdateService.
#
# That is the point of the split. Sharing the gate as a Python helper would have
# been equally DRY, but the gate would then be an honour system: any caller
# could still reach ECS directly, and a future edit that forgot to check would
# silently reopen it. Here it is IAM that makes the other Lambdas incapable of
# starting the server except through the gate.
#
# Created unconditionally. It is the ECS control plane, not a Discord feature —
# gating it on Discord would force a second, ungated code path in the relay for
# the default deployment, which is exactly what this design removes. Idle it
# costs nothing.
#
# Trade accepted: this is now a single point of failure for the start path,
# where previously two independent functions could start the server.
################################################################################

data "aws_caller_identity" "current" {}

locals {
  controller_name = "${local.name}-controller"

  # Self-reference: the function needs its own ARN (to target itself from the
  # one-shot stop schedules it creates) and the scheduler role needs it too.
  # Referencing aws_lambda_function.controller.arn from either would cycle, so
  # compose it from parts that are known ahead of the apply.
  controller_arn = "arn:aws:lambda:${local.region}:${data.aws_caller_identity.current.account_id}:function:${local.controller_name}"
}

data "archive_file" "controller" {
  type        = "zip"
  source_file = "${path.module}/lambda/controller.py"
  output_path = "${path.module}/lambda/controller.zip"
}

resource "aws_cloudwatch_log_group" "controller" {
  name              = "/aws/lambda/${local.controller_name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_lambda_function" "controller" {
  function_name    = local.controller_name
  role             = aws_iam_role.controller.arn
  runtime          = "python3.12"
  handler          = "controller.handler"
  filename         = data.archive_file.controller.output_path
  source_code_hash = data.archive_file.controller.output_base64sha256
  timeout          = 10
  tags             = local.tags

  environment {
    variables = {
      CLUSTER                    = aws_ecs_cluster.this.name
      SERVICE                    = aws_ecs_service.this.name
      GATE_PARAMETER             = aws_ssm_parameter.gate.name
      DOMAIN_NAME                = var.domain_name
      SNS_TOPIC_ARN              = aws_sns_topic.this.arn
      WAKE_TIMEZONE              = var.wake_timezone
      WAKE_WINDOWS               = jsonencode(var.wake_windows)
      CURFEW_WARNING_MINUTES     = tostring(var.curfew_warning_minutes)
      DISCORD_PRIVILEGED_ROLE_ID = var.discord_privileged_role_id
      SCHEDULE_GROUP             = aws_scheduler_schedule_group.this.name
      SCHEDULE_ROLE_ARN          = aws_iam_role.scheduler.arn
      FUNCTION_ARN               = local.controller_arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.controller]
}

resource "aws_iam_role" "controller" {
  name_prefix        = "${local.name}-controller-"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "controller" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }

  # Same dependency cycle as the task role's ScaleSelf statement (service ->
  # task def -> ... -> service), so the service ARN can't be referenced here.
  statement {
    sid       = "ControlService"
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadWriteGate"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [aws_ssm_parameter.gate.arn]
  }

  statement {
    sid       = "Notify"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.this.arn]
  }

  # One-shot schedules for a delayed stop (`/minecraft stop 10`). Scoped to the
  # module's own schedule group; PassRole is scoped to the single role those
  # schedules assume, and to the scheduler service.
  statement {
    sid     = "ScheduleDelayedStop"
    actions = ["scheduler:CreateSchedule", "scheduler:DeleteSchedule"]
    resources = [
      "arn:aws:scheduler:${local.region}:${data.aws_caller_identity.current.account_id}:schedule/${aws_scheduler_schedule_group.this.name}/*",
    ]
  }

  statement {
    sid       = "PassSchedulerRole"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.scheduler.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "controller" {
  name_prefix = "${local.name}-controller-"
  role        = aws_iam_role.controller.id
  policy      = data.aws_iam_policy_document.controller.json
}

################################################################################
# Shared caller policy
#
# The relay and the Discord command need exactly the same thing: write their own
# logs, and invoke the controller. Neither may touch ECS. Defining it once here
# also retires the byte-identical policy documents those two files used to carry.
################################################################################

data "aws_iam_policy_document" "invoke_controller" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }

  statement {
    sid       = "InvokeController"
    actions   = ["lambda:InvokeFunction"]
    resources = [local.controller_arn]
  }
}

################################################################################
# EventBridge Scheduler plumbing
#
# The group holds both the recurring curfew schedules (curfew.tf) and the
# one-shot delayed stops the controller creates at runtime, which delete
# themselves after firing.
################################################################################

resource "aws_scheduler_schedule_group" "this" {
  name = local.name
  tags = local.tags
}

resource "aws_iam_role" "scheduler" {
  name_prefix        = "${local.name}-scheduler-"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    # Confused-deputy guard: only this account's schedules may assume the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    sid       = "InvokeController"
    actions   = ["lambda:InvokeFunction"]
    resources = [local.controller_arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name_prefix = "${local.name}-scheduler-"
  role        = aws_iam_role.scheduler.id
  policy      = data.aws_iam_policy_document.scheduler.json
}
