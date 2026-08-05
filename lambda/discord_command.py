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
################################################################################

ecs = boto3.client("ecs")

PUBLIC_KEY = bytes.fromhex(os.environ["DISCORD_PUBLIC_KEY"])
CLUSTER = os.environ["CLUSTER"]
SERVICE = os.environ["SERVICE"]
DOMAIN_NAME = os.environ["DOMAIN_NAME"]
GUILD_ID = os.environ["DISCORD_GUILD_ID"]

# Discord signs the timestamp alongside the body, so rejecting stale timestamps
# closes the replay window a valid captured signature would otherwise leave open.
MAX_SIGNATURE_AGE = 300

PING = 1
APPLICATION_COMMAND = 2
CHANNEL_MESSAGE = 4
EPHEMERAL = 64


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


def _counts():
    services = ecs.describe_services(cluster=CLUSTER, services=[SERVICE])["services"]
    if not services:
        return 0, 0
    return services[0]["desiredCount"], services[0]["runningCount"]


def _start():
    desired, running = _counts()

    if desired > 0:
        state = "already running" if running > 0 else "already starting"
        return f"`{DOMAIN_NAME}` is {state}."

    ecs.update_service(cluster=CLUSTER, service=SERVICE, desiredCount=1)
    print(f"Started {SERVICE} (set desiredCount=1)")
    return (
        f"Starting `{DOMAIN_NAME}` :rocket:\n"
        "The world takes a few minutes to load — you'll get a message here once "
        "it's ready to join."
    )


def _status():
    desired, running = _counts()

    if desired == 0:
        return f"`{DOMAIN_NAME}` is asleep. Use `/minecraft start` to wake it."
    if running == 0:
        return f"`{DOMAIN_NAME}` is starting — the server task is still coming up."
    return (
        f"`{DOMAIN_NAME}` is up. If it won't accept connections yet, the world is "
        "still loading."
    )


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

    options = (interaction.get("data") or {}).get("options") or []
    subcommand = options[0]["name"] if options else "status"

    if subcommand == "start":
        return _reply(_start())
    return _reply(_status())
