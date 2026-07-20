################################################################################
# IAM
################################################################################

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: pull the container image and write logs.
resource "aws_iam_role" "execution" {
  name_prefix        = "${local.name}-exec-"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role: used by the watchdog sidecar to scale the service to zero, look up
# its own public IP, update the DNS record, and publish notifications.
resource "aws_iam_role" "task" {
  name_prefix        = "${local.name}-task-"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "task" {
  # UpdateService/DescribeServices can't be scoped to the service ARN without a
  # dependency cycle (service -> task def -> task role -> policy -> service), so
  # they stay unscoped. This is a single-purpose account/module.
  statement {
    sid       = "ScaleSelf"
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = ["*"]
  }

  statement {
    sid       = "DescribeEni"
    actions   = ["ec2:DescribeNetworkInterfaces"]
    resources = ["*"]
  }

  statement {
    sid = "UpdateDns"
    actions = [
      "route53:GetHostedZone",
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
    ]
    resources = [aws_route53_zone.this.arn]
  }

  statement {
    sid       = "Notify"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.this.arn]
  }

  # ECS Exec: the SSM agent in the container opens Session Manager channels using
  # the task role. Only granted when enable_ecs_exec = true. Not resource-scopable.
  dynamic "statement" {
    for_each = var.enable_ecs_exec ? [1] : []
    content {
      sid = "EcsExec"
      actions = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "task" {
  name_prefix = "${local.name}-task-"
  role        = aws_iam_role.task.id
  policy      = data.aws_iam_policy_document.task.json
}

################################################################################
# Launcher Lambda role (IAM is global; the function itself runs in us-east-1)
################################################################################

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "launcher" {
  name_prefix        = "${local.name}-launcher-"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "launcher" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }

  statement {
    sid       = "StartServer"
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "launcher" {
  name_prefix = "${local.name}-launcher-"
  role        = aws_iam_role.launcher.id
  policy      = data.aws_iam_policy_document.launcher.json
}
