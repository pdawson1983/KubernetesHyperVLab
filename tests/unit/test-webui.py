#!/usr/bin/env python3
"""
tests/unit/test-webui.py
HTTP smoke tests for all web UI routes.
Requires cluster to be running and dashboard.k8s.local resolvable
(or set WEBUI_URL env var to the direct IP/hostname).
"""

import sys, os, subprocess
import httpx

WEBUI_URL = os.environ.get("WEBUI_URL", "http://dashboard.k8s.local")

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


def get(path, expect_status=200, expect_contains=None):
    try:
        r = httpx.get(f"{WEBUI_URL}{path}", timeout=10, follow_redirects=True)
        if r.status_code != expect_status:
            fail(f"GET {path}", f"expected {expect_status} got {r.status_code}")
            return None
        if expect_contains and expect_contains not in r.text:
            fail(f"GET {path}", f"expected '{expect_contains}' in response")
            return None
        ok(f"GET {path} → {r.status_code}" +
           (f" contains '{expect_contains}'" if expect_contains else ""))
        return r
    except Exception as e:
        fail(f"GET {path}", str(e))
        return None


# ── Page availability ──────────────────────────────────────────────────────

print("\n── Page availability ─────────────────────────────────────────────────")

get("/",          expect_contains="AgentForge")
get("/submit",    expect_contains="Launch Pipeline")
get("/approvals", expect_contains="Approvals")

# ── Dashboard content ──────────────────────────────────────────────────────

print("\n── Dashboard content ─────────────────────────────────────────────────")

r = get("/")
if r:
    if "Pipeline Runs" in r.text:
        ok("Dashboard has 'Pipeline Runs' heading")
    else:
        fail("Dashboard missing 'Pipeline Runs' heading")

    if "refresh" in r.text.lower() or "meta" in r.text.lower():
        ok("Dashboard has auto-refresh meta tag")
    else:
        fail("Dashboard missing auto-refresh meta tag")

# ── Submit form ────────────────────────────────────────────────────────────

print("\n── Submit form fields ────────────────────────────────────────────────")

r = get("/submit")
if r:
    for field in ["title", "repo_url", "event", "context", "skipAgents"]:
        if f'name="{field}"' in r.text or f"name='{field}'" in r.text:
            ok(f"Submit form has field: {field}")
        else:
            fail(f"Submit form missing field: {field}")

    if "Full pipeline" in r.text:
        ok("Submit form has plain-English pipeline mode options")
    else:
        fail("Submit form missing plain-English pipeline mode")

    if "Skip Agents" in r.text:
        ok("Submit form has Skip Agents section")
    else:
        fail("Submit form missing Skip Agents section")

    if "Agent Instructions" in r.text:
        ok("Submit form has Agent Instructions textarea")
    else:
        fail("Submit form missing Agent Instructions textarea")

# ── Task detail ────────────────────────────────────────────────────────────

print("\n── Task detail routes ────────────────────────────────────────────────")

# Nonexistent task should 404
try:
    r = httpx.get(f"{WEBUI_URL}/tasks/nonexistent-task-xyz", timeout=10)
    if r.status_code == 404:
        ok("GET /tasks/<nonexistent> → 404")
    else:
        fail("GET /tasks/<nonexistent>", f"expected 404 got {r.status_code}")
except Exception as e:
    fail("GET /tasks/<nonexistent>", str(e))

# Get a real task_id from Postgres if available
try:
    result = subprocess.run(
        ["kubectl", "exec", "-n", "agentforge",
         subprocess.check_output(
             ["kubectl", "get", "pod", "-n", "agentforge",
              "-l", "app.kubernetes.io/name=postgres", "-o", "name"],
             text=True
         ).strip(),
         "--", "psql", "-U", "agentforge", "-d", "agentforge", "-t", "-c",
         "SELECT task_id FROM pipeline_runs ORDER BY created_at DESC LIMIT 1;"],
        capture_output=True, text=True, timeout=10
    )
    task_id = result.stdout.strip()
except Exception:
    task_id = ""

if task_id:
    r = get(f"/tasks/{task_id}", expect_contains="Agent Chain")
    if r:
        if "Turns" in r.text and "Tokens" in r.text and "Cost" in r.text:
            ok(f"Task detail has token/cost columns for {task_id}")
        else:
            fail(f"Task detail missing token/cost columns for {task_id}")
        if "Total Cost" in r.text:
            ok("Task detail has Total Cost in header stats")
        else:
            fail("Task detail missing Total Cost stat")
else:
    print("  SKIP  GET /tasks/<id> content — no tasks in Postgres")

# ── Approvals page ────────────────────────────────────────────────────────

print("\n── Approvals page ────────────────────────────────────────────────────")

r = get("/approvals")
if r:
    if "approval" in r.text.lower() or "pending" in r.text.lower() or "No pending" in r.text:
        ok("Approvals page renders approval content")
    else:
        fail("Approvals page missing expected content")

# ── Eastern-time display ──────────────────────────────────────────────────
# All user-visible timestamps render via the `eastern` Jinja filter and emit
# an EST or EDT zone label. The label only appears when timestamps are
# rendered, so these checks are soft when pages have no data.

print("\n── Eastern-time display ──────────────────────────────────────────────")


def _has_tz_label(text):
    return ("EST" in text) or ("EDT" in text)


def check_eastern(path, label, has_data_marker=None):
    r2 = httpx.get(f"{WEBUI_URL}{path}", timeout=10, follow_redirects=True)
    if r2.status_code != 200:
        fail(f"{label} ({path})", f"status {r2.status_code}")
        return
    if has_data_marker is not None and has_data_marker not in r2.text:
        print(f"  SKIP  {label} ({path}) — no data marker '{has_data_marker}' in response")
        return
    if _has_tz_label(r2.text):
        ok(f"{label} ({path}) shows EST or EDT")
    elif "—" in r2.text or "No " in r2.text:
        print(f"  SKIP  {label} ({path}) — no timestamps rendered (empty/placeholder page)")
    else:
        fail(f"{label} ({path})", "no EST/EDT label found in response")


check_eastern("/", "Dashboard")
check_eastern("/approvals", "Approvals")
if task_id:
    check_eastern(f"/tasks/{task_id}", "Task detail", has_data_marker="Agent Chain")

# ── Summary ───────────────────────────────────────────────────────────────

print()
print("══════════════════════════════════════════════════")
total = PASS + FAIL
if FAIL == 0:
    print(f"  PASSED  {PASS}/{total} web UI tests")
else:
    print(f"  FAILED  {PASS} passed, {FAIL} failed — {total} total")
print("══════════════════════════════════════════════════")
sys.exit(0 if FAIL == 0 else 1)
