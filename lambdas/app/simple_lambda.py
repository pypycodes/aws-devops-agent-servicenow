"""
SimpleLambda — triggered every 1 min by EventBridge.
Stress test: 60s continuous writes to DynamoDB.
"""

import boto3
import os
import time
import uuid
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ddb = boto3.resource("dynamodb")

TABLE = os.environ["STRESS_TABLE"]
DURATION = int(os.environ.get("STRESS_DURATION", "60"))
if not 1 <= DURATION <= 300:
    raise ValueError(f"STRESS_DURATION must be between 1 and 300, got {DURATION}")


def handler(event, context):
    run_id = str(uuid.uuid4())[:8]
    logger.info(f"Run {run_id} started — table={TABLE} duration={DURATION}s")

    table = ddb.Table(TABLE)
    writes, errors = 0, 0
    end_time = time.time() + DURATION
    logger.info(f"Starting DynamoDB stress test for {DURATION}s...")

    while time.time() < end_time:
        try:
            table.put_item(Item={
                "pk": f"stress-{run_id}-{writes}",
                "run_id": run_id,
                "seq": writes,
                "ts": int(time.time()),
                "data": "x" * 200,
            })
            writes += 1
        except Exception as e:
            errors += 1
            if errors <= 3:
                logger.error(f"Write error #{errors}: {type(e).__name__}: {e}")

    logger.info(f"Stress test complete — writes={writes} errors={errors} duration={DURATION}s")

    # Re-raise so AWS/Lambda Errors metric increments and ErrorAlarm fires (M9/T14)
    if errors > 0:
        raise RuntimeError(f"Stress test had {errors} write errors out of {writes + errors} attempts")

    return {"run_id": run_id, "writes": writes, "errors": errors}
