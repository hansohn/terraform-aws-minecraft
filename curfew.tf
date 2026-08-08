################################################################################
# Curfew — stop a RUNNING server when its window closes
#
# The gate only refuses to START. Without this, a session already in progress
# when the window closes carries on until the players leave and the watchdog's
# idle timer expires; the curfew is what makes the boundary real.
#
# Off by default: it disconnects players mid-session. The itzg image handles
# SIGTERM and saves the world, so there is no data loss, but the exit is abrupt
# — which is why the warning schedule fires first and the announcer sidecar
# (ecs.tf) says so in-game.
#
# Both schedules are DERIVED from var.wake_windows so there is exactly one
# definition of "when are we open". EventBridge Scheduler applies the timezone
# itself, including daylight saving, so these do not drift.
################################################################################

locals {
  curfew_enabled = var.enable_curfew && length(var.wake_windows) > 0

  day_after = {
    mon = "TUE", tue = "WED", wed = "THU", thu = "FRI",
    fri = "SAT", sat = "SUN", sun = "MON",
  }
  day_before = {
    MON = "SUN", TUE = "MON", WED = "TUE", THU = "WED",
    FRI = "THU", SAT = "FRI", SUN = "SAT",
  }

  # Per window: when does it close, and on which weekday(s) does that fall?
  # A window whose end is earlier than its start wraps past midnight, so its
  # close lands on the day AFTER each listed day.
  curfew_windows = local.curfew_enabled ? {
    for idx, w in var.wake_windows : "w${idx}" => {
      start_total = tonumber(split(":", w.start)[0]) * 60 + tonumber(split(":", w.start)[1])
      end_total   = tonumber(split(":", w.end)[0]) * 60 + tonumber(split(":", w.end)[1])
      wraps       = (tonumber(split(":", w.start)[0]) * 60 + tonumber(split(":", w.start)[1])) > (tonumber(split(":", w.end)[0]) * 60 + tonumber(split(":", w.end)[1]))
      stop_days = [
        for d in w.days :
        (tonumber(split(":", w.start)[0]) * 60 + tonumber(split(":", w.start)[1])) > (tonumber(split(":", w.end)[0]) * 60 + tonumber(split(":", w.end)[1]))
        ? local.day_after[lower(d)] : upper(d)
      ]
    }
  } : {}

  # The warning fires curfew_warning_minutes before the close. If that lands
  # before midnight it belongs to the previous weekday.
  curfew_warnings = {
    for key, w in local.curfew_windows : key => {
      total = (w.end_total - var.curfew_warning_minutes + 1440) % 1440
      days = (w.end_total - var.curfew_warning_minutes) < 0 ? [
        for d in w.stop_days : local.day_before[d]
      ] : w.stop_days
    }
  }
}

################################################################################
# In-game announcer
#
# The out-of-game warning (email, and Discord via the SNS subscriber) reaches
# whoever is watching a phone; this reaches whoever is actually playing.
#
# It runs as a sidecar rather than a Lambda because in awsvpc mode every
# container in the task shares one network namespace: RCON is reachable on
# localhost and is never exposed to the VPC, so there is no port to open, no
# security group pair, and no VPC-attached Lambda needing a NAT gateway.
#
# The sidecar holds a copy of the window closes and does its own arithmetic, so
# it needs no AWS credentials or API access at all. Consequence worth knowing:
# it can only warn about SCHEDULED closes. An ad-hoc `/minecraft stop 10` warns
# through Discord and email but not in-game.
################################################################################

resource "random_password" "rcon" {
  count   = local.curfew_enabled ? 1 : 0
  length  = 32
  special = false
}

locals {
  # Window closes per weekday, as minutes since local midnight.
  curfew_ends_by_day = {
    for day in ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"] :
    lower(day) => distinct(flatten([
      for _, w in local.curfew_windows : contains(w.stop_days, day) ? [w.end_total] : []
    ]))
  }

  curfew_announcer_image = var.curfew_announcer_image != "" ? var.curfew_announcer_image : local.container_image

  # Announce at these remaining-minute marks rather than every minute, so a ten
  # minute warning is four messages instead of ten.
  curfew_announce_at = [10, 5, 2, 1]

  curfew_announcer_script = <<-EOT
    set -eu
    # Wait for the server to accept RCON before trying to talk to it.
    until rcon-cli list >/dev/null 2>&1; do sleep 10; done
    last=""
    while true; do
      d=$(date +%a | tr '[:upper:]' '[:lower:]')
      now=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
      ends=""
      case "$d" in
    ${join("\n", [
  for day, ends in local.curfew_ends_by_day :
  "    ${day}) ends=\"${join(" ", ends)}\" ;;" if length(ends) > 0
])}
      esac
      for e in $ends; do
        left=$(( e - now ))
        case "$left" in
    ${join("|", [for m in local.curfew_announce_at : tostring(m)])})
            if [ "$d-$e-$left" != "$last" ]; then
              rcon-cli say "Server stops in $left minute(s)."
              last="$d-$e-$left"
            fi
            ;;
        esac
      done
      sleep 20
    done
  EOT
}

resource "aws_scheduler_schedule" "curfew_stop" {
  for_each = local.curfew_windows

  name       = "${local.name}-curfew-stop-${each.key}"
  group_name = aws_scheduler_schedule_group.this.name

  schedule_expression          = "cron(${each.value.end_total % 60} ${floor(each.value.end_total / 60)} ? * ${join(",", each.value.stop_days)} *)"
  schedule_expression_timezone = var.wake_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.controller.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ action = "stop", source = "schedule", reason = "curfew" })
  }
}

resource "aws_scheduler_schedule" "curfew_warn" {
  for_each = var.curfew_warning_minutes > 0 ? local.curfew_warnings : {}

  name       = "${local.name}-curfew-warn-${each.key}"
  group_name = aws_scheduler_schedule_group.this.name

  schedule_expression          = "cron(${each.value.total % 60} ${floor(each.value.total / 60)} ? * ${join(",", each.value.days)} *)"
  schedule_expression_timezone = var.wake_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.controller.arn
    role_arn = aws_iam_role.scheduler.arn
    input = jsonencode({
      action  = "warn"
      source  = "schedule"
      minutes = var.curfew_warning_minutes
    })
  }
}
