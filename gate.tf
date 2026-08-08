################################################################################
# Wake gate state
#
# Split by how often things change. The WINDOWS are declarative Terraform
# config (var.wake_windows) and reach the controller as an environment
# variable — they belong in version control and change maybe twice a year.
# Only the MUTABLE bits live here: the current mode, any temporary override,
# and any pending stop. Discord writes them through the controller; an operator
# with no Discord integration writes them with the AWS CLI:
#
#   aws ssm put-parameter --name <gate_parameter_name output> --overwrite \
#     --value '{"version":1,"mode":"disable"}'
#
# Standard tier: parameters are free and standard-throughput API calls are free.
################################################################################

locals {
  # Seeded WITHOUT "override" or "pending_stop" — absent means none, which
  # avoids the null-versus-missing ambiguity in the Lambda's read path.
  gate_default = jsonencode({
    version = 1
    mode    = var.wake_default_mode
  })
}

resource "aws_ssm_parameter" "gate" {
  name        = "/${local.name}/gate"
  type        = "String"
  tier        = "Standard"
  value       = local.gate_default
  description = "Runtime wake-gate state for ${var.domain_name}: mode, temporary override, pending stop."
  tags        = local.tags

  lifecycle {
    # The controller rewrites this on every gate change, exactly as the watchdog
    # rewrites the A record in dns.tf — so Terraform seeds it and then keeps its
    # hands off. Consequence worth knowing: var.wake_default_mode is a
    # CREATE-TIME setting. Changing it later will never update an existing
    # parameter; use the /minecraft gate subcommands or put-parameter instead.
    ignore_changes = [value]
  }
}
