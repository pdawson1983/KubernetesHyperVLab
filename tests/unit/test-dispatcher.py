#!/usr/bin/env python3
"""
tests/unit/test-dispatcher.py
HTTP tests for all dispatcher endpoints.
Requires cluster to be running (uses kubectl port-forward or direct service IP).
"""

import sys, os, json, hmac, hashlib, subprocess, time
import httpx

DISPATCHER_URL = os.environ.get("DISPATCHER_URL", "http://webhook.k8s.local")
NAMESPACE      = os.environ.get("NAMESPACE", "agentforge")

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    print(f"  PASS  {msg}")
    PASS += 1


def fail(msg, detail=""):
    global FAIL
    print(f"  FAIL  {msg}" + (f": {detail}" if detail else ""))
    FAIL += 1


def get_webhook_secret():
    result = subprocess.run(
        ["kubectl", "get", "secret", "webhook-secret", "-n", NAMESPACE,
         "-o", "jsonpath={.data.WEBHOOK_SECRET}"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return b""
    import base64
    return base64.b64decode(result.stdout.strip())


SECRET = get_webhook_secret()


def sign(payload_bytes):
    if not SECRET:
        return ""
    return "sha256=" + hmac.new(SECRET, payload_bytes, hashlib.sha256).hexdigest()


# ── Health endpoints ───────────────────────────────────────────────────────

print("\n── Health endpoints ──────────────────────────────────────────────────")

for path in ["/healthz", "/readyz"]:
    try:
        r = httpx.get(f"{DISPATCHER_URL}{path}", timeout=5)
        if r.status_code == 200 and r.json().get("status") == "ok":
            ok(f"GET {path} → 200 {{status:ok}}")
        else:
            fail(f"GET {path}", f"status={r.status_code} body={r.text[:100]}")
    except Exception as e:
        fail(f"GET {path}", str(e))

# ── GET /tasks ─────────────────────────────────────────────────────────────

print("\n── GET /tasks ────────────────────────────────────────────────────────")

try:
    r = httpx.get(f"{DISPATCHER_URL}/tasks", timeout=5)
    if r.status_code == 200:
        data = r.json()
        if isinstance(data, list):
            ok(f"GET /tasks → 200 list ({len(data)} tasks)")
            if data:
                t = data[0]
                required = ["task_id", "status"]
                missing = [k for k in required if k not in t]
                if not missing:
                    ok("GET /tasks first item has task_id and status")
                else:
                    fail("GET /tasks first item missing fields", str(missing))
        else:
            fail("GET /tasks response is not a list", type(data).__name__)
    else:
        fail("GET /tasks", f"status={r.status_code}")
except Exception as e:
    fail("GET /tasks", str(e))

# ── GET /task/<id> ────────────────────────────────────────────────────────

print("\n── GET /task/<id> ────────────────────────────────────────────────────")

# Get a real task_id from /tasks (NFS-live), not Postgres (may have been cleaned up)
try:
    r = httpx.get(f"{DISPATCHER_URL}/tasks", timeout=5)
    live_tasks = r.json() if r.status_code == 200 else []
    task_id = live_tasks[0]["task_id"] if live_tasks else ""
except Exception:
    task_id = ""

if task_id:
    try:
        r = httpx.get(f"{DISPATCHER_URL}/task/{task_id}", timeout=5)
        if r.status_code == 200:
            data = r.json()
            if data.get("task_id") == task_id:
                ok(f"GET /task/{task_id} → 200 with correct task_id")
            else:
                fail(f"GET /task/{task_id}", f"task_id mismatch: {data.get('task_id')}")
        else:
            fail(f"GET /task/{task_id}", f"status={r.status_code}")
    except Exception as e:
        fail(f"GET /task/<id>", str(e))
else:
    print("  SKIP  GET /task/<id> — no completed tasks in Postgres")

try:
    r = httpx.get(f"{DISPATCHER_URL}/task/nonexistent-task-id-xyz", timeout=5)
    if r.status_code == 404:
        ok("GET /task/<nonexistent> → 404")
    else:
        fail("GET /task/<nonexistent>", f"expected 404 got {r.status_code}")
except Exception as e:
    fail("GET /task/<nonexistent>", str(e))

# ── GET /pending ──────────────────────────────────────────────────────────

print("\n── GET /pending ──────────────────────────────────────────────────────")

try:
    r = httpx.get(f"{DISPATCHER_URL}/pending", timeout=5)
    if r.status_code == 200:
        data = r.json()
        if isinstance(data, list):
            ok(f"GET /pending → 200 list ({len(data)} pending)")
        else:
            fail("GET /pending response not a list", type(data).__name__)
    else:
        fail("GET /pending", f"status={r.status_code}")
except Exception as e:
    fail("GET /pending", str(e))

# ── POST / — HMAC validation ──────────────────────────────────────────────

print("\n── POST / — HMAC validation ──────────────────────────────────────────")

payload = json.dumps({"event": "issue.opened", "title": "test"}).encode()
bad_sig = "sha256=0000000000000000000000000000000000000000000000000000000000000000"

try:
    r = httpx.post(
        f"{DISPATCHER_URL}/",
        content=payload,
        headers={"Content-Type": "application/json",
                 "X-Event-Type": "issue.opened",
                 "X-Hub-Signature-256": bad_sig},
        timeout=5
    )
    if r.status_code == 401:
        ok("POST / with bad HMAC → 401")
    else:
        fail("POST / with bad HMAC", f"expected 401 got {r.status_code}")
except Exception as e:
    fail("POST / HMAC rejection", str(e))

if SECRET:
    sig = sign(payload)
    try:
        r = httpx.post(
            f"{DISPATCHER_URL}/",
            content=payload,
            headers={"Content-Type": "application/json",
                     "X-Event-Type": "issue.opened",
                     "X-Hub-Signature-256": sig},
            timeout=10
        )
        if r.status_code in (200, 202):
            data = r.json()
            if "task_id" in data or "awaiting_approval" in data:
                ok(f"POST / with valid HMAC → {r.status_code} with task_id")
            else:
                fail("POST / valid HMAC", f"no task_id in response: {data}")
        else:
            fail("POST / valid HMAC", f"status={r.status_code} body={r.text[:200]}")
    except Exception as e:
        fail("POST / valid HMAC", str(e))

# ── POST /approve/<nonexistent> ───────────────────────────────────────────

print("\n── POST /approve/<id> ────────────────────────────────────────────────")

try:
    r = httpx.post(f"{DISPATCHER_URL}/approve/nonexistent-task-xyz", timeout=5)
    if r.status_code == 404:
        ok("POST /approve/<nonexistent> → 404")
    else:
        fail("POST /approve/<nonexistent>", f"expected 404 got {r.status_code}")
except Exception as e:
    fail("POST /approve/<nonexistent>", str(e))

# ── Summary ───────────────────────────────────────────────────────────────

print()
print("══════════════════════════════════════════════════")
total = PASS + FAIL
if FAIL == 0:
    print(f"  PASSED  {PASS}/{total} dispatcher tests")
else:
    print(f"  FAILED  {PASS} passed, {FAIL} failed — {total} total")
print("══════════════════════════════════════════════════")
sys.exit(0 if FAIL == 0 else 1)
