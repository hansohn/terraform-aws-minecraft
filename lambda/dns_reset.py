"""Park the server DNS record on a placeholder when the task stops.

Triggered by an EventBridge rule on ECS Task State Change (lastStatus STOPPED).
The watchdog only UPSERTs the task's public IP at startup and never cleans up,
so without this the A record keeps pointing at an address AWS later recycles to
another account. Resetting it makes a stopped server refuse connections
immediately instead of timing out against a stranger's host.
"""

import os

import boto3

ecs = boto3.client("ecs")
route53 = boto3.client("route53")

CLUSTER = os.environ["CLUSTER"]
SERVICE = os.environ["SERVICE"]
ZONE_ID = os.environ["ZONE_ID"]
DOMAIN_NAME = os.environ["DOMAIN_NAME"]
PLACEHOLDER_IP = os.environ["PLACEHOLDER_IP"]
RECORD_TTL = int(os.environ["RECORD_TTL"])


def handler(event, context):
    # Spot reclamation also stops the task, but ECS then launches a replacement
    # whose watchdog writes the real IP — resetting would clobber it. The
    # watchdog zeroes desiredCount *before* the task stops, so a deliberate
    # shutdown already reads 0 here while an interruption still reads 1.
    services = ecs.describe_services(cluster=CLUSTER, services=[SERVICE])["services"]
    desired = services[0]["desiredCount"] if services else 0

    if desired > 0:
        print(f"{SERVICE} still desires {desired} task(s); leaving DNS alone")
        return {"reset": False}

    route53.change_resource_record_sets(
        HostedZoneId=ZONE_ID,
        ChangeBatch={
            "Comment": "Minecraft server stopped; parking record on placeholder",
            "Changes": [
                {
                    "Action": "UPSERT",
                    "ResourceRecordSet": {
                        "Name": DOMAIN_NAME,
                        "Type": "A",
                        "TTL": RECORD_TTL,
                        "ResourceRecords": [{"Value": PLACEHOLDER_IP}],
                    },
                }
            ],
        },
    )
    print(f"Reset {DOMAIN_NAME} to {PLACEHOLDER_IP}")
    return {"reset": True}
