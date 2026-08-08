"""Relay a Route53 query-log delivery to the controller.

A CloudWatch Logs subscription filter on the Route53 query log fires this
whenever anyone resolves the server hostname. It forwards a start request to the
controller and returns; the controller decides whether that request is honoured.

This function deliberately inspects NOTHING. The subscription filter matches
every event, and looking at query names or record types here would be a false
comfort: three of the five queries in the incident that motivated the gate were
plain A lookups, indistinguishable from a real player. Authorisation is a
question about time and policy, not about the packet, so it lives in one place
and this stays a wire.

Invoked asynchronously — CloudWatch Logs discards the return value, so there is
nothing to wait for, and Lambda's async retry is safe because setting
desiredCount to 1 is idempotent.
"""

import json
import os

import boto3

lambda_client = boto3.client("lambda", region_name=os.environ["REGION"])

CONTROLLER_ARN = os.environ["CONTROLLER_ARN"]


def handler(event, context):
    lambda_client.invoke(
        FunctionName=CONTROLLER_ARN,
        InvocationType="Event",
        Payload=json.dumps({"action": "start", "source": "dns"}).encode(),
    )
    print("Forwarded a DNS wake request to the controller")
    return {"forwarded": True}
