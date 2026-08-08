"""Discord slash command that wakes the server and reports its status.

Backs a Lambda Function URL registered as the Discord application's
interactions endpoint. Discord signs every request with Ed25519 and probes the
endpoint with deliberately bad signatures before accepting it, so the signature
check is mandatory — it is the only thing guarding a public, unauthenticated
URL. Verification is implemented here rather than pulled from PyNaCl so the
function stays a single stdlib file, deployable straight from the module with
no build step.
"""

import base64
import hashlib
import json
import os
import time

import boto3
from botocore.config import Config

################################################################################
# Ed25519 verification (RFC 8032)
#
# Extended homogeneous coordinates (X, Y, Z, T) keep this to one modular
# inversion per verify — a few milliseconds, comfortably inside Discord's
# 3-second interaction deadline. The naive affine reference implementation
# inverts on every point operation and is far too slow to use here.
################################################################################

_P = 2**255 - 19
_L = 2**252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_SQRT_M1 = pow(2, (_P - 1) // 4, _P)


def _recover_x(y, sign):
    if y >= _P:
        return None
    xx = (y * y - 1) * pow(_D * y * y + 1, _P - 2, _P) % _P
    if xx == 0:
        return None if sign else 0
    x = pow(xx, (_P + 3) // 8, _P)
    if (x * x - xx) % _P != 0:
        x = x * _SQRT_M1 % _P
    if (x * x - xx) % _P != 0:
        return None
    if x & 1 != sign:
        x = _P - x
    return x


def _point_add(p1, p2):
    x1, y1, z1, t1 = p1
    x2, y2, z2, t2 = p2
    a = (y1 - x1) * (y2 - x2) % _P
    b = (y1 + x1) * (y2 + x2) % _P
    c = 2 * t1 * t2 * _D % _P
    d = 2 * z1 * z2 % _P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % _P, g * h % _P, f * g % _P, e * h % _P)


def _point_mul(s, p):
    q = (0, 1, 1, 0)  # neutral element
    while s > 0:
        if s & 1:
            q = _point_add(q, p)
        p = _point_add(p, p)
        s >>= 1
    return q


def _point_equal(p1, p2):
    x1, y1, z1, _ = p1
    x2, y2, z2, _ = p2
    return (x1 * z2 - x2 * z1) % _P == 0 and (y1 * z2 - y2 * z1) % _P == 0


def _point_decompress(data):
    if len(data) != 32:
        return None
    y = int.from_bytes(data, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    return None if x is None else (x, y, 1, x * y % _P)


_G_Y = 4 * pow(5, _P - 2, _P) % _P
_G = (_recover_x(_G_Y, 0), _G_Y, 1, _recover_x(_G_Y, 0) * _G_Y % _P)


def _verify(public_key, message, signature):
    """Return True if signature is a valid Ed25519 signature over message."""
    if len(signature) != 64:
        return False
    a = _point_decompress(public_key)
    if a is None:
        return False
    r = _point_decompress(signature[:32])
    if r is None:
        return False
    s = int.from_bytes(signature[32:], "little")
    if s >= _L:
        return False
    h = (
        int.from_bytes(
            hashlib.sha512(signature[:32] + public_key + message).digest(), "little"
        )
        % _L
    )
    return _point_equal(_point_mul(s, _G), _point_add(r, _point_mul(h, a)))


################################################################################
# Interaction handling
#
# This function verifies Discord's signature, works out which subcommand was
# invoked, and forwards it to the controller. It holds no ECS permissions: the
# controller is the only thing that can start or stop the service, and it
# re-derives privilege from the role IDs inside the signed body rather than
# trusting anything computed here.
#
# All player-facing wording lives in this file so the controller stays
# Discord-agnostic and returns structured JSON.
################################################################################

lambda_client = boto3.client(
    "lambda",
    # Discord gives an interaction three seconds. Bound the call so a slow
    # controller degrades into a readable message instead of Discord's
    # "The application did not respond".
    config=Config(connect_timeout=1, read_timeout=2, retries={"max_attempts": 0}),
)

PUBLIC_KEY = bytes.fromhex(os.environ["DISCORD_PUBLIC_KEY"])
CONTROLLER = os.environ["CONTROLLER_FUNCTION_NAME"]
DOMAIN_NAME = os.environ["DOMAIN_NAME"]
GUILD_ID = os.environ["DISCORD_GUILD_ID"]

# Discord signs the timestamp alongside the body, so rejecting stale timestamps
# closes the replay window a valid captured signature would otherwise leave open.
MAX_SIGNATURE_AGE = 300

PING = 1
APPLICATION_COMMAND = 2
CHANNEL_MESSAGE = 4
EPHEMERAL = 64

SUB_COMMAND = 1
SUB_COMMAND_GROUP = 2

MODE_SUBCOMMANDS = ("enable", "disable", "schedule")
OVERRIDE_SUBCOMMANDS = ("allow", "block")


def _json(payload, status=200):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def _reply(content, ephemeral=False):
    data = {"content": content}
    if ephemeral:
        data["flags"] = EPHEMERAL
    return _json({"type": CHANNEL_MESSAGE, "data": data})


def _subcommand(interaction):
    """(group, name, args) for the invoked subcommand.

    Gate operations are nested under a subcommand group so their verbs cannot be
    misread as per-player actions — "block" in a Minecraft server means a great
    deal of things, and none of them are this.
    """
    options = (interaction.get("data") or {}).get("options") or []
    if not options:
        return None, "status", {}

    first = options[0]
    if first.get("type") == SUB_COMMAND_GROUP:
        inner = (first.get("options") or [{}])[0]
        args = {o["name"]: o.get("value") for o in (inner.get("options") or [])}
        return first.get("name"), inner.get("name", "status"), args

    args = {o["name"]: o.get("value") for o in (first.get("options") or [])}
    return None, first.get("name", "status"), args


def _call(action, interaction, **extra):
    """Invoke the controller and return its structured verdict."""
    member = interaction.get("member") or {}
    user_id = (member.get("user") or {}).get("id")

    payload = {
        "action": action,
        "source": "discord",
        "guild_id": interaction.get("guild_id"),
        "user_id": user_id,
        # Sent for the controller to CHECK, not as a claim of privilege. These
        # come from the body Discord signed, so they are trustworthy input.
        "member_role_ids": member.get("roles") or [],
        "by": f"discord:{user_id}" if user_id else "discord",
    }
    payload.update(extra)

    response = lambda_client.invoke(
        FunctionName=CONTROLLER,
        InvocationType="RequestResponse",
        Payload=json.dumps(payload).encode(),
    )
    return json.loads(response["Payload"].read() or b"{}")


def _gate_summary(gate):
    if not gate:
        return ""

    mode = gate.get("mode", "enable")
    if mode == "enable":
        detail = "open to anyone who resolves the hostname"
    elif mode == "disable":
        detail = "closed — DNS lookups will not start it"
    else:
        detail = "following the schedule"
        if not gate.get("allowed") and gate.get("next_open"):
            detail += f", next open {gate['next_open'][:16].replace('T', ' ')}"
        elif gate.get("allowed"):
            detail += ", currently within hours"

    if gate.get("override_until"):
        detail += f" (override until {gate['override_until'][:16].replace('T', ' ')})"

    return f"Gate: **{mode}** — {detail}."


def _handle(interaction):
    group, name, args = _subcommand(interaction)

    if group == "gate":
        if name in MODE_SUBCOMMANDS:
            result = _call("set_mode", interaction, mode=name)
        elif name in OVERRIDE_SUBCOMMANDS:
            result = _call(
                "override", interaction, state=name, minutes=args.get("minutes") or 0
            )
        else:
            return _reply("Unknown gate subcommand.", ephemeral=True)

        if result.get("error"):
            return _reply(f":lock: {result['error']}.", ephemeral=True)
        if result.get("cleared"):
            return _reply(f"Override cleared. {_gate_summary(result.get('gate'))}")
        return _reply(_gate_summary(result.get("gate")) or "Gate updated.")

    if name == "start":
        result = _call("start", interaction)
        if result.get("error"):
            return _reply(f":lock: {result['error']}.", ephemeral=True)
        if result.get("started"):
            return _reply(
                f"Starting `{DOMAIN_NAME}` :rocket:\n"
                "The world takes a few minutes to load — you'll get a message here "
                "once it's ready to join."
            )
        state = "running" if result.get("running") else "starting"
        return _reply(f"`{DOMAIN_NAME}` is already {state}.")

    if name == "stop":
        minutes = args.get("minutes") or 0
        result = _call("stop", interaction, minutes=minutes)
        if result.get("error"):
            return _reply(f":lock: {result['error']}.", ephemeral=True)
        if result.get("scheduled"):
            return _reply(
                f"`{DOMAIN_NAME}` will stop in {minutes} minutes. Players have been "
                "warned."
            )
        if result.get("stopped"):
            return _reply(f"`{DOMAIN_NAME}` is shutting down.")
        return _reply(f"`{DOMAIN_NAME}` is already asleep.")

    result = _call("status", interaction)
    if result.get("error"):
        return _reply(f":warning: {result['error']}.", ephemeral=True)

    if result.get("desired", 0) == 0:
        line = f"`{DOMAIN_NAME}` is asleep."
    elif result.get("running", 0) == 0:
        line = f"`{DOMAIN_NAME}` is starting — the task is still coming up."
    else:
        line = (
            f"`{DOMAIN_NAME}` is up. If it won't accept connections yet, the world "
            "is still loading."
        )

    pending = result.get("pending_stop")
    if pending and pending.get("at"):
        line += f"\nScheduled to stop at {pending['at'][:16].replace('T', ' ')}."

    summary = _gate_summary(result.get("gate"))
    return _reply(f"{line}\n{summary}" if summary else line)


def handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    raw = event.get("body") or ""
    body = base64.b64decode(raw) if event.get("isBase64Encoded") else raw.encode()

    timestamp = headers.get("x-signature-timestamp", "")
    try:
        signature = bytes.fromhex(headers.get("x-signature-ed25519", ""))
    except ValueError:
        return _json({"error": "invalid request signature"}, status=401)

    if not _verify(PUBLIC_KEY, timestamp.encode() + body, signature):
        return _json({"error": "invalid request signature"}, status=401)

    try:
        age = abs(time.time() - int(timestamp))
    except ValueError:
        return _json({"error": "invalid request signature"}, status=401)

    if age > MAX_SIGNATURE_AGE:
        return _json({"error": "expired request"}, status=401)

    interaction = json.loads(body)

    if interaction.get("type") == PING:
        return _json({"type": PING})

    if interaction.get("type") != APPLICATION_COMMAND:
        return _json({"error": "unsupported interaction type"}, status=400)

    # The app could be installed in another guild; the signature only proves the
    # request came from Discord, not that it came from a server we serve.
    if GUILD_ID and interaction.get("guild_id") != GUILD_ID:
        return _reply("This command isn't enabled here.", ephemeral=True)

    try:
        return _handle(interaction)
    except Exception as exc:  # noqa: BLE001 - never leave Discord without a reply
        print(f"controller call failed: {exc}")
        return _reply(
            ":warning: Couldn't reach the server controller. Try again in a moment.",
            ephemeral=True,
        )
