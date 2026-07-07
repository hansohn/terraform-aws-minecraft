################################################################################
# DNS (Route53) + query logging
#
# The hosted zone is global. Route53 query logging for a public zone, however,
# REQUIRES its CloudWatch log group in us-east-1 — so the log group, its resource
# policy, and the launcher plumbing (see lambda.tf) use the aws.us_east_1
# provider while everything else stays in the compute region.
################################################################################

resource "aws_route53_zone" "this" {
  name = var.domain_name
  tags = local.tags
}

# The watchdog rewrites this A record to the task's public IP each time the
# server boots, so Terraform only seeds a placeholder and ignores later changes.
resource "aws_route53_record" "this" {
  zone_id = aws_route53_zone.this.zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = 30
  records = ["127.0.0.1"]

  lifecycle {
    ignore_changes = [records]
  }
}

resource "aws_cloudwatch_log_group" "querylog" {
  provider          = aws.us_east_1
  name              = "/aws/route53/${var.domain_name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

data "aws_iam_policy_document" "querylog" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.querylog.arn}:*"]

    principals {
      type        = "Service"
      identifiers = ["route53.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "querylog" {
  provider        = aws.us_east_1
  policy_name     = "${local.name}-route53-query-logging"
  policy_document = data.aws_iam_policy_document.querylog.json
}

resource "aws_route53_query_log" "this" {
  zone_id                  = aws_route53_zone.this.zone_id
  cloudwatch_log_group_arn = aws_cloudwatch_log_group.querylog.arn

  depends_on = [aws_cloudwatch_log_resource_policy.querylog]
}
