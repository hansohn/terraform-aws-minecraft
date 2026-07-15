################################################################################
# ECS (Fargate) + watchdog
#
# The service normally runs desired_count = 0 (nothing billed). The launcher
# Lambda scales it to 1 on demand; the watchdog sidecar scales it back to 0.
################################################################################

resource "aws_cloudwatch_log_group" "server" {
  name              = "/ecs/${local.name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_ecs_cluster" "this" {
  name = local.name
  tags = local.tags

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  tags                     = local.tags

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  volume {
    name = "data"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.this.id
      transit_encryption = "ENABLED"

      authorization_config {
        access_point_id = aws_efs_access_point.this.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name        = "minecraft"
      image       = var.minecraft_image
      essential   = true
      environment = [for k, v in local.minecraft_environment : { name = k, value = v }]

      portMappings = concat(
        [{
          containerPort = var.minecraft_port
          hostPort      = var.minecraft_port
          protocol      = "tcp"
        }],
        var.enable_bedrock ? [{
          containerPort = var.bedrock_port
          hostPort      = var.bedrock_port
          protocol      = "udp"
        }] : [],
      )

      mountPoints = [{
        sourceVolume  = "data"
        containerPath = "/data"
        readOnly      = false
      }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.server.name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "minecraft"
        }
      }
    },
    {
      name      = "watchdog"
      image     = var.watchdog_image
      essential = true

      environment = [
        { name = "CLUSTER", value = aws_ecs_cluster.this.name },
        { name = "SERVICE", value = local.name },
        { name = "DNSZONE", value = aws_route53_zone.this.zone_id },
        { name = "SERVERNAME", value = var.domain_name },
        { name = "SNSTOPIC", value = aws_sns_topic.this.arn },
        { name = "STARTUPMIN", value = tostring(var.startup_minutes) },
        { name = "SHUTDOWNMIN", value = tostring(var.shutdown_minutes) },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.server.name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "watchdog"
        }
      }
    },
  ])
}

resource "aws_ecs_service" "this" {
  name            = local.name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = 0
  propagate_tags  = "SERVICE"
  tags            = local.tags

  capacity_provider_strategy {
    capacity_provider = var.use_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
    base              = 1
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.server.id]
    assign_public_ip = true
  }

  # desired_count is driven at runtime by the launcher Lambda and watchdog.
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_ecs_cluster_capacity_providers.this]
}
