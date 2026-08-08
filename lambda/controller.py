"""Sole authority for starting and stopping the Minecraft service.

Every wake path routes through here: the us-east-1 relay forwards DNS query-log
events, the Discord slash command forwards interactions, and EventBridge fires
curfew warnings and stops. Those callers hold `lambda:InvokeFunction` on this
function and nothing else — this role is the only one carrying
`ecs:UpdateService`, so the gate below is not an honour system a future edit can
forget to consult. It is the only way to reach the service.

The gate answers one question: may the server start right now, for this caller?
Two inputs, split by how often they change. WAKE_WINDOWS and WAKE_TIMEZONE are
declarative Terraform config baked into the environment. Mutable state — the
mode, plus any temporary override — lives in one SSM parameter that Discord and
the AWS CLI can write without a deploy.

Resolution order is: unexpired override, then mode, then (in "schedule" mode)
the windows. An empty window list imposes nothing, which is what keeps the
feature opt-in.

Failures fail CLOSED. A bad timezone or an unreadable parameter denies the
start and says so loudly, because failing open silently voids a curfew while
failing closed is recoverable in one command.
"""

import json
import os
import time
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import boto3

ecs = boto3.client("ecs")
ssm = boto3.client("ssm")
sns = boto3.client("sns")
scheduler = boto3.client("scheduler")

CLUSTER = os.environ["CLUSTER"]
SERVICE = os.environ["SERVICE"]
GATE_PARAMETER = os.environ["GATE_PARAMETER"]
DOMAIN_NAME = os.environ.get("DOMAIN_NAME", "")
WAKE_TIMEZONE = os.environ.get("WAKE_TIMEZONE", "UTC")
WAKE_WINDOWS = json.loads(os.environ.get("WAKE_WINDOWS") or "[]")
PRIVILEGED_ROLE_ID = os.environ.get("DISCORD_PRIVILEGED_ROLE_ID", "")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
CURFEW_WARNING_MINUTES = int(os.environ.get("CURFEW_WARNING_MINUTES") or "10")
SCHEDULE_GROUP = os.environ.get("SCHEDULE_GROUP", "")
SCHEDULE_ROLE_ARN = os.environ.get("SCHEDULE_ROLE_ARN", "")
FUNCTION_ARN = os.environ.get("FUNCTION_ARN", "")

DAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
MODES = ("enable", "disable", "schedule")

# Warm containers reuse this. Short enough that a Discord gate change takes
# effect almost immediately, long enough to absorb a scanner burst arriving as
# one batched subscription-filter delivery.
_CACHE_TTL_SECONDS = 5
_cache = {"at": 0.0, "state": None}


################################################################################
# Gate state (SSM)
################################################################################


def _load_state():
    now = time.monotonic()
    if _cache["state"] is not None and now - _cache["at"] < _CACHE_TTL_SECONDS:
        return _cache["state"]

    raw = ssm.get_parameter(Name=GATE_PARAMETER)["Parameter"]["Value"]
    state = json.loads(raw)
    _cache["at"] = now
    _cache["state"] = state
    return state


def _save_state(state, by):
    state["updated_at"] = _now().isoformat()
    state["updated_by"] = by
    ssm.put_parameter(Name=GATE_PARAMETER, Value=json.dumps(state), Overwrite=True)
    # Keep the warm container consistent with what we just wrote, so a follow-up
    # /minecraft status in the same second does not report the previous value.
    _cache["at"] = time.monotonic()
    _cache["state"] = state
    return state


def _now():
    return datetime.now(timezone.utc)


def _parse_iso(value):
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


################################################################################
# Window arithmetic
#
# Times are compared as minutes-since-local-midnight. A window whose end is
# earlier than its start wraps past midnight and belongs to its START day, so
# "fri 22:00-02:00" keeps running into Saturday morning without needing a
# Saturday entry.
################################################################################


def _minutes(hhmm):
    hours, minutes = str(hhmm).split(":")
    return int(hours) * 60 + int(minutes)


def _days_of(window):
    return {str(day).lower() for day in window.get("days", [])}


def _in_windows(local):
    if not WAKE_WINDOWS:
        return True

    now = local.hour * 60 + local.minute
    today = DAYS[local.weekday()]
    yesterday = DAYS[(local.weekday() - 1) % 7]

    for window in WAKE_WINDOWS:
        days = _days_of(window)
        start, end = _minutes(window["start"]), _minutes(window["end"])

        if start < end:
            if today in days and start <= now < end:
                return True
        elif start > end:
            if (today in days and now >= start) or (yesterday in days and now < end):
                return True
        # start == end is a zero-length window and never matches.

    return False


def _next_open(local):
    """First window start strictly after `local`, or None if unrestricted."""
    if not WAKE_WINDOWS:
        return None

    for offset in range(0, 8):
        day = local + timedelta(days=offset)
        name = DAYS[day.weekday()]
        starts = sorted(
            _minutes(w["start"]) for w in WAKE_WINDOWS if name in _days_of(w)
        )
        for start in starts:
            candidate = day.replace(
                hour=start // 60, minute=start % 60, second=0, microsecond=0
            )
            if candidate > local:
                return candidate.isoformat()

    return None


################################################################################
# Gate resolution
################################################################################


def _resolve(state):
    """(allowed, reason, next_open) for a DNS-originated start attempt."""
    override = state.get("override")
    if override:
        until = _parse_iso(override.get("until"))
        if until and _now() < until:
            allowed = override.get("state") == "allow"
            return allowed, "override", override.get("until")
        # An expired override is ignored, never deleted here — the read path
        # stays free of writes. The next privileged write cleans it up.

    mode = state.get("mode", "enable")
    if mode == "disable":
        return False, "disabled", None
    if mode == "enable":
        return True, "enabled", None

    try:
        zone = ZoneInfo(WAKE_TIMEZONE)
    except Exception as exc:  # noqa: BLE001 - any failure here must fail closed
        print(f"FAILING CLOSED: wake_timezone {WAKE_TIMEZONE!r} unusable: {exc}")
        return False, "timezone-error", None

    local = _now().astimezone(zone)
    if _in_windows(local):
        return True, "in-window", None
    return False, "out-of-window", _next_open(local)


def _gate_view(state, allowed, reason, next_open):
    return {
        "mode": state.get("mode", "enable"),
        "allowed": allowed,
        "reason": reason,
        "next_open": next_open,
        "override_until": (state.get("override") or {}).get("until"),
        "timezone": WAKE_TIMEZONE,
        "windows": len(WAKE_WINDOWS),
    }


################################################################################
# ECS
################################################################################


def _counts():
    services = ecs.describe_services(cluster=CLUSTER, services=[SERVICE])["services"]
    if not services:
        return 0, 0
    return services[0]["desiredCount"], services[0]["runningCount"]


def _set_desired(count):
    ecs.update_service(cluster=CLUSTER, service=SERVICE, desiredCount=count)


def _publish(subject, message):
    if not SNS_TOPIC_ARN:
        return
    sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject[:100], Message=message)


################################################################################
# Actions
################################################################################


def _do_start(source, state):
    desired, running = _counts()

    if source == "discord":
        allowed, reason, next_open = True, "privileged", None
    else:
        allowed, reason, next_open = _resolve(state)

    if not allowed:
        print(
            f"DENIED start from {source}: {reason}"
            + (f" (next open {next_open})" if next_open else "")
        )
        return {
            "action": "start",
            "allowed": False,
            "started": False,
            "desired": desired,
            "running": running,
            "gate": _gate_view(state, False, reason, next_open),
        }

    if desired > 0:
        return {
            "action": "start",
            "allowed": True,
            "started": False,
            "desired": desired,
            "running": running,
            "gate": _gate_view(state, True, reason, next_open),
        }

    _set_desired(1)
    print(f"Started {SERVICE} (desiredCount=1) for {source}: {reason}")
    return {
        "action": "start",
        "allowed": True,
        "started": True,
        "desired": 1,
        "running": running,
        "gate": _gate_view(state, True, reason, next_open),
    }


def _do_stop(event, state):
    desired, running = _counts()
    delay = int(event.get("minutes") or 0)

    if desired == 0:
        return {
            "action": "stop",
            "stopped": False,
            "scheduled": False,
            "desired": 0,
            "running": running,
            "gate": _gate_view(state, *_resolve(state)),
        }

    if delay > 0:
        at = _now() + timedelta(minutes=delay)
        _schedule_stop(at, event.get("reason") or "requested")
        state["pending_stop"] = {
            "at": at.isoformat(),
            "reason": event.get("reason") or "requested",
        }
        _save_state(state, event.get("by") or "controller")
        _publish(
            f"{DOMAIN_NAME or SERVICE} stopping in {delay} min",
            f"The server will stop at {at.isoformat()} ({event.get('reason') or 'requested'}).",
        )
        return {
            "action": "stop",
            "stopped": False,
            "scheduled": True,
            "at": at.isoformat(),
            "desired": desired,
            "running": running,
            "gate": _gate_view(state, *_resolve(state)),
        }

    _set_desired(0)
    state.pop("pending_stop", None)
    _save_state(state, event.get("by") or "controller")
    print(f"Stopped {SERVICE} (desiredCount=0): {event.get('reason') or 'requested'}")
    return {
        "action": "stop",
        "stopped": True,
        "scheduled": False,
        "desired": 0,
        "running": running,
        "gate": _gate_view(state, *_resolve(state)),
    }


def _do_warn(event, state):
    """Curfew pre-announcement. In-game warnings come from the announcer
    sidecar, which derives them from the same windows; this covers the
    out-of-game channels (email, and Discord via the SNS subscriber)."""
    desired, _ = _counts()
    minutes = int(event.get("minutes") or CURFEW_WARNING_MINUTES)

    if desired == 0:
        return {"action": "warn", "sent": False, "reason": "not running"}

    _publish(
        f"{DOMAIN_NAME or SERVICE} stopping in {minutes} min",
        f"Curfew: the server stops in about {minutes} minutes.",
    )
    return {"action": "warn", "sent": True, "minutes": minutes}


def _do_status(state):
    desired, running = _counts()
    allowed, reason, next_open = _resolve(state)
    return {
        "action": "status",
        "desired": desired,
        "running": running,
        "domain": DOMAIN_NAME,
        "pending_stop": state.get("pending_stop"),
        "gate": _gate_view(state, allowed, reason, next_open),
    }


def _do_set_mode(event, state):
    mode = event.get("mode")
    if mode not in MODES:
        return {"error": f"mode must be one of {', '.join(MODES)}"}

    state["mode"] = mode
    state.pop("override", None)  # an explicit mode change clears any override
    _save_state(state, event.get("by") or "unknown")
    allowed, reason, next_open = _resolve(state)
    return {
        "action": "set_mode",
        "mode": mode,
        "gate": _gate_view(state, allowed, reason, next_open),
    }


def _do_override(event, state):
    wanted = event.get("state")
    minutes = int(event.get("minutes") or 0)

    if wanted not in ("allow", "block"):
        return {"error": "override state must be \"allow\" or \"block\""}

    if minutes <= 0:
        state.pop("override", None)
    else:
        state["override"] = {
            "state": wanted,
            "until": (_now() + timedelta(minutes=minutes)).isoformat(),
            "by": event.get("by") or "unknown",
        }

    _save_state(state, event.get("by") or "unknown")
    allowed, reason, next_open = _resolve(state)
    return {
        "action": "override",
        "cleared": minutes <= 0,
        "gate": _gate_view(state, allowed, reason, next_open),
    }


################################################################################
# Delayed stop scheduling
################################################################################


def _schedule_stop(at, reason):
    """One-shot EventBridge schedule that deletes itself after firing."""
    if not (SCHEDULE_GROUP and SCHEDULE_ROLE_ARN and FUNCTION_ARN):
        print("No scheduler configuration; delayed stop will not fire")
        return

    name = f"{SERVICE}-stop-{int(at.timestamp())}"
    scheduler.create_schedule(
        Name=name,
        GroupName=SCHEDULE_GROUP,
        ScheduleExpression=f"at({at.strftime('%Y-%m-%dT%H:%M:%S')})",
        ScheduleExpressionTimezone="UTC",
        FlexibleTimeWindow={"Mode": "OFF"},
        ActionAfterCompletion="DELETE",
        Target={
            "Arn": FUNCTION_ARN,
            "RoleArn": SCHEDULE_ROLE_ARN,
            "Input": json.dumps(
                {"action": "stop", "source": "schedule", "reason": reason}
            ),
        },
    )
    print(f"Scheduled stop {name} at {at.isoformat()}")


################################################################################
# Authorisation
#
# Only Discord-originated requests can be privileged, and privilege is derived
# HERE from the role IDs Discord signed — never from a boolean the caller sends.
# That keeps the role ID in one place and makes this function's log the single
# record of who was granted what. Other sources reach us only through IAM, and
# are trusted for the narrow set of actions they can send.
################################################################################


def _is_privileged(event):
    if event.get("source") != "discord":
        return False
    if not PRIVILEGED_ROLE_ID:
        # No role configured: guild membership alone suffices, matching the
        # pre-0.8.0 behaviour so upgrades do not lock existing users out.
        return True
    return PRIVILEGED_ROLE_ID in (event.get("member_role_ids") or [])


PRIVILEGED_ACTIONS = ("start", "stop", "set_mode", "override")


def handler(event, context):
    action = event.get("action") or "status"
    source = event.get("source") or "unknown"

    if action in PRIVILEGED_ACTIONS and source == "discord" and not _is_privileged(event):
        return {"error": "not permitted", "action": action, "privileged": False}

    if action in ("stop", "set_mode", "override", "warn") and source not in (
        "discord",
        "schedule",
    ):
        return {"error": "not permitted", "action": action, "source": source}

    try:
        state = _load_state()
    except Exception as exc:  # noqa: BLE001 - unreadable gate must fail closed
        print(f"FAILING CLOSED: cannot read {GATE_PARAMETER}: {exc}")
        if action == "start":
            return {
                "action": "start",
                "allowed": False,
                "started": False,
                "gate": {"reason": "gate-unreadable", "allowed": False},
            }
        return {"error": "gate unreadable", "action": action}

    if action == "start":
        return _do_start(source, state)
    if action == "stop":
        return _do_stop(event, state)
    if action == "warn":
        return _do_warn(event, state)
    if action == "set_mode":
        return _do_set_mode(event, state)
    if action == "override":
        return _do_override(event, state)
    if action == "status":
        return _do_status(state)

    return {"error": f"unknown action {action!r}"}
