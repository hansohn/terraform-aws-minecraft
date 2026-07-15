"""Forward SNS start/stop notifications to a Discord channel webhook.

Subscribed to the module's SNS topic. Each SNS record's message is posted to
the webhook in DISCORD_WEBHOOK_URL. Uses only the standard library so the
function needs no packaged dependencies.
"""

import json
import os
import urllib.request

WEBHOOK_URL = os.environ["DISCORD_WEBHOOK_URL"]


def handler(event, context):
    for record in event.get("Records", []):
        message = record["Sns"]["Message"]
        payload = json.dumps({"content": message}).encode("utf-8")
        req = urllib.request.Request(
            WEBHOOK_URL,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
