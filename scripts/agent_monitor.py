#!/usr/bin/env python3
"""
AWS DevOps Agent Monitor
Watches investigations, triggers mitigation via send-message, displays execution plans.
Usage: python3 agent_monitor.py <agent-space-id>
"""

import boto3
import json
import os
import time
import re
import sys
import textwrap
from datetime import datetime

REGION = "us-east-1"
POLL_INTERVAL = 30
WAIT_TIMEOUT = 600
USER_ID = os.environ.get("USER_ID", "demo-user")


def wait(seconds):
    """Intentional delay for polling loops."""
    time.sleep(seconds)

# Terminal styling
C = {
    "g": "\033[38;5;114m", "y": "\033[38;5;222m", "c": "\033[38;5;117m",
    "r": "\033[38;5;210m", "m": "\033[38;5;183m", "d": "\033[38;5;243m",
    "b": "\033[1m", "0": "\033[0m",
}


def ts():
    return datetime.now().strftime("%H:%M:%S")


def log(msg):
    print(f"  {C['d']}[{ts()}]{C['0']} {msg}")


# --- Execution ID helpers ---

# executionId comes back from list_executions/get_task prefixed like
# "exe-ops1-3bc58497-29fb-4fc1-a5a2-8f2a6a0d3f05", but send_message's
# executionId param is validated server-side against a bare UUID regex
# (^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$).
# Strip the "exe-<agentType>-" prefix down to just the UUID before
# passing it to send_message. Other calls (get_task, list_journal_records)
# keep using the full prefixed id since that's the resource identifier.
EXECUTION_UUID_RE = re.compile(
    r'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'
)


def bare_execution_id(eid):
    """Extract the bare UUID suffix from a prefixed executionId.
    Returns the input unchanged if it doesn't match the expected pattern."""
    if not eid:
        return eid
    m = EXECUTION_UUID_RE.search(eid)
    return m.group(1) if m else eid


# --- API calls ---

def make_client():
    return boto3.client("devops-agent", region_name=REGION)


def list_tasks(cl, sid):
    return cl.list_backlog_tasks(agentSpaceId=sid)["tasks"]


def get_task(cl, sid, tid):
    return cl.get_backlog_task(agentSpaceId=sid, taskId=tid)["task"]


def fetch_journal(cl, sid, eid):
    """Fetch all journal records, handling pagination."""
    records, params = [], {"agentSpaceId": sid, "executionId": eid}
    while True:
        resp = cl.list_journal_records(**params)
        records.extend(resp.get("records", []))
        if "nextToken" in resp:
            params["nextToken"] = resp["nextToken"]
        else:
            return records


def trigger_mitigation(cl, sid, eid):
    """Send message to the investigation execution to trigger mitigation plan generation.
    This is the programmatic equivalent of clicking 'Generate mitigation plan' in the console.

    executionId comes back prefixed like 'exe-ops1-3bc58497-...-8f2a6a0d3f05'. We try the
    full prefixed id first (this is what the console appears to use, per observed behavior),
    and only fall back to the bare UUID suffix if that call fails.

    Security: Plans are displayed for human review only — no auto-execution of remediation.
    """
    attempts = [("full", eid)]
    stripped = bare_execution_id(eid)
    if stripped != eid:
        attempts.append(("stripped", stripped))

    last_err = None
    for label, exec_id in attempts:
        try:
            log(f"{C['d']}debug: trying executionId ({label})={exec_id!r}{C['0']}")
            cl.send_message(
                agentSpaceId=sid,
                executionId=exec_id,
                content="Generate mitigation plan",
            )
            return True
        except Exception as e:
            last_err = e
            log(f"{C['r']}send-message failed ({label}): {e}{C['0']}")

    return False


# --- Journal parsers ---

def extract_finding(records):
    """Get root cause finding from journal."""
    for r in records:
        if r.get("recordType") == "finding":
            try:
                content = json.loads(r.get("content", "{}"))
                return content if isinstance(content, dict) else None
            except (json.JSONDecodeError, TypeError):
                return None
    return None


def extract_mitigation(records):
    """Get mitigation plan from final_response record (created after mitigation runs)."""
    for r in records:
        if r.get("recordType") == "final_response":
            try:
                msg = json.loads(r["content"])
                for item in msg.get("content", []):
                    if item.get("text"):
                        return item["text"]
            except (json.JSONDecodeError, TypeError):
                return r["content"]
    return None


# --- Display ---

def banner(sid):
    w = 54
    print(f"\n  {C['c']}{'━' * w}{C['0']}")
    print(f"  {C['c']}┃{C['0']}  {C['b']}AWS DevOps Agent Monitor{C['0']}{' ' * (w - 24)}{C['c']}┃{C['0']}")
    print(f"  {C['c']}{'━' * w}{C['0']}")
    print(f"  {C['d']}Space:{C['0']}  {sid}")
    print(f"  {C['d']}Region:{C['0']} {REGION}")
    print(f"  {C['d']}Poll:{C['0']}   {POLL_INTERVAL}s")
    print(f"  {C['c']}{'━' * w}{C['0']}\n")


def show_task(task):
    print(f"  {C['d']}├─{C['0']} ID:       {task['taskId']}")
    print(f"  {C['d']}├─{C['0']} Title:    {task['title']}")
    print(f"  {C['d']}├─{C['0']} Type:     {task['taskType']}")
    print(f"  {C['d']}├─{C['0']} Priority: {task['priority']}")
    print(f"  {C['d']}└─{C['0']} Created:  {task['createdAt']}")
    print(f"  {C['d']}├─{C['0']} Exec ID:  {task['executionId']}") #added new


def show_rca(finding):
    print(f"\n  {C['y']}▸ ROOT CAUSE{C['0']}")
    for line in textwrap.wrap(finding.get("title", "Unknown"), 68):
        print(f"  {C['d']}│{C['0']}  {line}")
    desc = finding.get("description", "")
    if desc:
        print(f"  {C['d']}│{C['0']}")
        for line in textwrap.wrap(desc, 68):
            print(f"  {C['d']}│{C['0']}  {C['d']}{line}{C['0']}")
    print()


def show_mitigation(text):
    print(f"  {C['m']}▸ MITIGATION PLAN{C['0']}")
    print(f"  {C['d']}{'─' * 50}{C['0']}")
    print(f"\n{text}\n")


# --- Wait loop ---

def await_completion(cl, sid, tid):
    """Poll task until terminal state."""
    elapsed = 0
    while elapsed < WAIT_TIMEOUT:
        rem = WAIT_TIMEOUT - elapsed
        print(f"\r  {C['d']}⧖ waiting... {rem}s remaining{C['0']}   ", end="", flush=True)
        wait(10)
        elapsed += 10
        task = get_task(cl, sid, tid)
        if task["status"] in ("COMPLETED", "FAILED", "TIMED_OUT", "CANCELLED"):
            print(f"\r  {C['d']}⧖ done{C['0']}" + " " * 30)
            return task
    print(f"\r  {C['r']}⧖ timed out{C['0']}" + " " * 30)
    return None


# --- Main loop ---

def run(space_id):
    cl = make_client()
    states = {}      # tid -> last status
    handled = set()  # investigations already mitigated

    banner(space_id)

    # Seed with existing tasks so we only act on NEW status transitions
    for task in list_tasks(cl, space_id):
        states[task["taskId"]] = task["status"]
        if task["status"] == "COMPLETED":
            handled.add(task["taskId"])
    log(f"{C['d']}seeded {len(states)} existing task(s), skipping old investigations{C['0']}")
    print()

    while True:
        try:
            tasks = list_tasks(cl, space_id)
            active = sum(1 for t in tasks if t["status"] == "IN_PROGRESS")
            print(f"  {C['d']}[{ts()}]{C['0']} {active} active task(s)")

            for task in tasks:
                tid, status = task["taskId"], task["status"]
                ttype = task["taskType"]
                prev = states.get(tid)
                states[tid] = status

                # New in-progress task
                if prev is None and status == "IN_PROGRESS":
                    print(f"\n  {C['d']}[{ts()}]{C['0']} {C['c']}● new task{C['0']}")
                    show_task(task)
                    print()

                # Status transition
                if prev and prev != status:
                    log(f"{tid[:12]}… {C['y']}{prev}{C['0']} → {C['g']}{status}{C['0']}")

                # Investigation completed — show RCA, trigger mitigation via send-message
                if (ttype == "INVESTIGATION"
                        and status == "COMPLETED"
                        and tid not in handled):
                    handled.add(tid)
                    eid = task.get("executionId")
                    if not eid:
                        continue

                    # Show root cause
                    records = fetch_journal(cl, space_id, eid)
                    finding = extract_finding(records)
                    if finding:
                        show_rca(finding)

                    # Trigger mitigation by sending message to the investigation execution
                    log(f"{C['m']}▶ triggering mitigation for: {tid[:12]}…{C['0']}")
                    if trigger_mitigation(cl, space_id, eid):
                        log(f"{C['g']}mitigation triggered{C['0']}")

                        # Wait for investigation to complete again (now with mitigation)
                        log(f"⧖ waiting for mitigation to complete…")
                        result = await_completion(cl, space_id, tid)

                        if result and result["status"] == "COMPLETED":
                            log(f"{C['g']}✔ mitigation complete{C['0']}\n")
                            # Fetch updated journal with mitigation records
                            updated_records = fetch_journal(cl, space_id, eid)
                            plan = extract_mitigation(updated_records)
                            if plan:
                                show_mitigation(plan)
                            else:
                                log(f"{C['d']}no mitigation plan found in journal{C['0']}")
                        elif result:
                            log(f"{C['r']}mitigation ended: {result['status']}{C['0']}")
                    print()

        except KeyboardInterrupt:
            print(f"\n  {C['d']}stopped.{C['0']}\n")
            sys.exit(0)
        except Exception as e:
            log(f"{C['r']}error: {e}{C['0']}")

        try:
            wait(POLL_INTERVAL)
        except KeyboardInterrupt:
            print(f"\n  {C['d']}stopped.{C['0']}\n")
            sys.exit(0)


def select_space(cl):
    """List agent spaces and let user pick one. Skips prompt if only one exists."""
    spaces = cl.list_agent_spaces().get("agentSpaces", [])
    if not spaces:
        print(f"  {C['r']}No agent spaces found.{C['0']}")
        sys.exit(1)
    if len(spaces) == 1:
        s = spaces[0]
        print(f"  {C['d']}Using agent space:{C['0']} {s['name']} ({s['agentSpaceId']})\n")
        return s["agentSpaceId"]
    print(f"\n  {C['c']}Available Agent Spaces:{C['0']}\n")
    for i, s in enumerate(spaces, 1):
        print(f"  {C['d']}[{i}]{C['0']} {s['name']}  {C['d']}{s['agentSpaceId']}{C['0']}")
    print()
    while True:
        try:
            choice = int(input(f"  Select [1-{len(spaces)}]: "))
            if 1 <= choice <= len(spaces):
                return spaces[choice - 1]["agentSpaceId"]
        except (ValueError, KeyboardInterrupt):
            print(f"\n  {C['d']}cancelled.{C['0']}\n")
            sys.exit(0)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        space_id = sys.argv[1]
        if not re.match(r'^[a-f0-9-]{36}$', space_id):
            print(f"  {C['r']}Invalid agent space ID format{C['0']}")
            sys.exit(1)
        run(space_id)
    else:
        cl = make_client()
        run(select_space(cl))
