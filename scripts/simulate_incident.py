#!/usr/bin/env python3
"""
Trigger incident by switching DynamoDB from on-demand to provisioned (2 WCU).
The SimpleLambda keeps writing every minute — throttling starts immediately.

Usage: python3 simulate_incident.py [env]
       python3 simulate_incident.py demo restore   # restore on-demand
"""

import boto3
import re
import sys

REGION = "us-east-1"
ENV = sys.argv[1] if len(sys.argv) > 1 else "demo"
CMD = sys.argv[2] if len(sys.argv) > 2 else "inject"

if not re.match(r'^[a-zA-Z0-9_-]+$', ENV):
    print("Error: ENV must be alphanumeric with hyphens/underscores only")
    sys.exit(1)
if CMD not in ("inject", "restore"):
    print(f"Error: unknown command '{CMD}'. Use 'inject' or 'restore'")
    sys.exit(1)
TABLE = f"{ENV}-stress-test-table"
ALARM = f"{ENV}-DynamoDB-WriteThrottle"

ddb = boto3.client("dynamodb", region_name=REGION)
cw = boto3.client("cloudwatch", region_name=REGION)


def inject():
    print(f"🔥 Injecting fault: switching {TABLE} to provisioned (2 WCU)")
    try:
        ddb.update_table(
            TableName=TABLE,
            BillingMode="PROVISIONED",
            ProvisionedThroughput={"ReadCapacityUnits": 5, "WriteCapacityUnits": 2},
        )
    except Exception as e:
        print(f"❌ Error: {e}")
        sys.exit(1)
    print(f"✅ Table now at 2 WCU — SimpleLambda runs every minute doing 60s of writes")
    print(f"   Throttling will start on next Lambda invocation")
    print(f"   Alarm: {ALARM}")
    print(f"\n   Restore: python3 {sys.argv[0]} {ENV} restore")


def restore():
    print(f"🔧 Restoring {TABLE} to on-demand")
    try:
        ddb.update_table(TableName=TABLE, BillingMode="PAY_PER_REQUEST")
    except Exception as e:
        print(f"❌ Error: {e}")
        sys.exit(1)
    print(f"✅ Table restored to on-demand — throttling will stop")


if CMD == "restore":
    restore()
else:
    inject()
