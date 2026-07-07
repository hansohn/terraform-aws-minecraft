"""Wake the Minecraft server on a Route53 DNS query.

Triggered by a CloudWatch Logs subscription filter on the Route53 query log
group. Any invocation means someone tried to resolve the server hostname, so we
set the ECS service desired count to 1. The call is idempotent — if the service
is already running we do nothing. The watchdog sidecar scales it back to 0 when
the server goes idle.
"""

import os

import boto3

ecs = boto3.client("ecs", region_name=os.environ["REGION"])

CLUSTER = os.environ["CLUSTER"]
SERVICE = os.environ["SERVICE"]


def handler(event, context):
    services = ecs.describe_services(cluster=CLUSTER, services=[SERVICE])["services"]
    desired = services[0]["desiredCount"] if services else 0

    if desired > 0:
        print(f"{SERVICE} already running (desiredCount={desired}); nothing to do")
        return {"running": True, "started": False}

    ecs.update_service(cluster=CLUSTER, service=SERVICE, desiredCount=1)
    print(f"Started {SERVICE} (set desiredCount=1)")
    return {"running": True, "started": True}
