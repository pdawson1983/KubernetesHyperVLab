#!/usr/bin/env python3
"""
tests/unit/test-eastern-time.py
Unit tests for the Eastern-time display helper (fmt_eastern) in
claude-agent/web-ui/app.py.

Runs without a cluster and without installing the web-UI's runtime deps:
asyncpg / httpx / fastapi are stubbed in sys.modules before app.py is loaded
so the module-level decorators and type hints don't fail. The test then
exercises fmt_eastern directly across DST boundaries, None input, and naive
datetimes.

Covers spec §5 of improvement-spec.md:
  1. Winter UTC -> EST  (Jan 15 17:00 UTC -> 12:00 EST)
  2. Summer UTC -> EDT  (Jul 15 17:00 UTC -> 13:00 EDT)
  3. None         -> '—'
  4. Naive UTC    -> assumed UTC, no exception
"""

import importlib.util
import pathlib
import sys
import types
from datetime import datetime, timezone
from unittest.mock import MagicMock

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  PASS  {msg}")


def fail(msg, detail=""):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {msg}" + (f": {detail}" if detail else ""))


def assert_eq(actual, expected, label):
    if actual == expected:
        ok(f"{label}: {actual!r}")
    else:
        fail(label, f"expected {expected!r}, got {actual!r}")


# ── Stub heavy imports so app.py can be loaded ────────────────────────────

def _make_stub(name, attrs=None):
    mod = types.ModuleType(name)
    for k, v in (attrs or {}).items():
        setattr(mod, k, v)
    sys.modules[name] = mod
    return mod


_make_stub("asyncpg", {"Pool": MagicMock(), "create_pool": MagicMock()})
# httpx is usually installed but stub defensively so the test is self-contained
if "httpx" not in sys.modules:
    _make_stub("httpx", {"AsyncClient": MagicMock()})

class _FakeFastAPIApp:
    """FastAPI app stub whose route decorators (@app.get/post/...) return the
    wrapped function unchanged, so route handlers remain callable as plain
    async functions in unit tests. A bare MagicMock would wrap each handler
    in a MagicMock and break direct invocation."""

    def _route_decorator(self, *args, **kwargs):
        return lambda f: f

    get = post = put = delete = patch = options = head = _route_decorator


class _FakeFastAPI:
    def __call__(self, *args, **kwargs):
        return _FakeFastAPIApp()


fastapi = _make_stub(
    "fastapi",
    {"FastAPI": _FakeFastAPI(), "Form": MagicMock(), "Request": MagicMock()},
)
_make_stub(
    "fastapi.responses",
    {"HTMLResponse": MagicMock(), "RedirectResponse": MagicMock()},
)


class _Jinja2TemplatesStub:
    """Minimal stand-in for fastapi.templating.Jinja2Templates.

    app.py does `templates.env.filters["eastern"] = fmt_eastern`, so the
    stub needs an `env.filters` dict that survives the assignment — a plain
    MagicMock would silently absorb the write.
    """

    def __init__(self, *args, **kwargs):
        self.env = types.SimpleNamespace(filters={})


_make_stub("fastapi.templating", {"Jinja2Templates": _Jinja2TemplatesStub})


# ── Load app.py by path ───────────────────────────────────────────────────

APP_PATH = (
    pathlib.Path(__file__).resolve().parents[2]
    / "claude-agent" / "web-ui" / "app.py"
)
spec = importlib.util.spec_from_file_location("webui_app", APP_PATH)
webui_app = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(webui_app)
except Exception as e:
    print(f"  FAIL  could not load {APP_PATH}: {e}")
    sys.exit(1)


fmt_eastern = webui_app.fmt_eastern
EASTERN = webui_app.EASTERN


# ── Spec §5 cases ─────────────────────────────────────────────────────────

print("\n── fmt_eastern: spec §5 cases ────────────────────────────────────────")

# 1. Winter UTC -> EST
winter = datetime(2026, 1, 15, 17, 0, tzinfo=timezone.utc)
assert_eq(
    fmt_eastern(winter, "%Y-%m-%d %H:%M %Z"),
    "2026-01-15 12:00 EST",
    "winter UTC -> EST",
)

# 2. Summer UTC -> EDT
summer = datetime(2026, 7, 15, 17, 0, tzinfo=timezone.utc)
assert_eq(
    fmt_eastern(summer, "%Y-%m-%d %H:%M %Z"),
    "2026-07-15 13:00 EDT",
    "summer UTC -> EDT",
)

# 3. None -> '—'  (matches fmt_cost / fmt_tokens / fmt_duration convention)
assert_eq(fmt_eastern(None), "—", "None -> em-dash")
assert_eq(
    fmt_eastern(None, "%Y-%m-%d %H:%M %Z"),
    "—",
    "None -> em-dash (custom fmt arg ignored)",
)

# 4. Naive datetime is assumed UTC (no exception)
naive_winter = datetime(2026, 1, 15, 17, 0)  # no tzinfo
try:
    result = fmt_eastern(naive_winter, "%Y-%m-%d %H:%M %Z")
    assert_eq(result, "2026-01-15 12:00 EST", "naive datetime treated as UTC")
except Exception as e:
    fail("naive datetime treated as UTC", f"raised {type(e).__name__}: {e}")


# ── Additional sanity checks ──────────────────────────────────────────────

print("\n── fmt_eastern: additional sanity ────────────────────────────────────")

# DST spring-forward boundary: 2026-03-08 06:30 UTC is 01:30 EST (still EST,
# the change happens at 07:00 UTC == 02:00 EST -> 03:00 EDT)
spring_before = datetime(2026, 3, 8, 6, 30, tzinfo=timezone.utc)
assert_eq(
    fmt_eastern(spring_before, "%Y-%m-%d %H:%M %Z"),
    "2026-03-08 01:30 EST",
    "30 min before US spring-forward stays EST",
)

# After spring-forward: 2026-03-08 07:30 UTC is 03:30 EDT
spring_after = datetime(2026, 3, 8, 7, 30, tzinfo=timezone.utc)
assert_eq(
    fmt_eastern(spring_after, "%Y-%m-%d %H:%M %Z"),
    "2026-03-08 03:30 EDT",
    "30 min after US spring-forward is EDT",
)

# Default format (the helper's default kwarg) includes seconds and zone
default_fmt = fmt_eastern(winter)
if default_fmt == "2026-01-15 12:00:00 EST":
    ok(f"default format: {default_fmt!r}")
else:
    fail("default format", f"expected '2026-01-15 12:00:00 EST', got {default_fmt!r}")


# ── EASTERN constant ──────────────────────────────────────────────────────

print("\n── module constants ──────────────────────────────────────────────────")

if str(EASTERN) == "America/New_York":
    ok("EASTERN is America/New_York")
else:
    fail("EASTERN constant", f"expected 'America/New_York', got {EASTERN!r}")


# ── Filter registration ───────────────────────────────────────────────────

print("\n── Jinja filter registration ─────────────────────────────────────────")

if webui_app.templates.env.filters.get("eastern") is fmt_eastern:
    ok("templates.env.filters['eastern'] is fmt_eastern")
else:
    fail(
        "filter registration",
        f"templates.env.filters['eastern'] = "
        f"{webui_app.templates.env.filters.get('eastern')!r}",
    )


# ── /approvals enrichment: created_at must become a datetime ─────────────
#
# Regression guard for the bug where approvals_page passed the dispatcher's
# raw string created_at straight to the `eastern` filter, which then crashed
# with AttributeError ('str' has no attribute 'tzinfo'). The filter contract
# is "tz-aware datetime in, formatted string out"; approvals_page is therefore
# responsible for converting the dispatcher's ISO-8601 string before render.

print("\n── approvals_page: created_at converted from str to datetime ────────")

import asyncio


class _FakeResp:
    def __init__(self, data, status_code=200):
        self._data = data
        self.status_code = status_code

    def json(self):
        return self._data


class _FakeClient:
    def __init__(self, pending_data):
        self._data = pending_data

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, tb):
        return None

    async def get(self, url, timeout=None):
        return _FakeResp(self._data)


class _FakeDB:
    async def fetch(self, query, *args, **kwargs):
        return [
            {"task_id": "20260517-044738-8ad6", "title": "stub", "repo_url": ""}
        ]


_pending_from_dispatcher = [
    {"task_id": "20260517-044738-8ad6", "created_at": "2026-05-17T04:47:38Z"}
]


class _CapturingTemplates:
    def __init__(self):
        self.captured = {}
        self.env = types.SimpleNamespace(filters={})

    def TemplateResponse(self, name, ctx):
        self.captured = ctx
        return MagicMock()


# Patch only the references that approvals_page reads from the module's globals.
# We don't touch the real httpx / asyncpg modules — just the names webui_app sees.
webui_app.httpx = types.SimpleNamespace(
    AsyncClient=lambda *a, **k: _FakeClient(_pending_from_dispatcher)
)
webui_app.db = _FakeDB()
_capturing = _CapturingTemplates()
webui_app.templates = _capturing

try:
    asyncio.run(webui_app.approvals_page(MagicMock()))
    pending_out = _capturing.captured.get("pending", [])
    if not pending_out:
        fail(
            "approvals_page populates pending",
            "no pending entries captured from template context",
        )
    else:
        created = pending_out[0].get("created_at")
        if isinstance(created, datetime):
            ok(
                f"approvals_page converts dispatcher str created_at to datetime: "
                f"{created!r}"
            )
            # Verify the converted value flows cleanly through fmt_eastern,
            # which is the exact path that previously crashed.
            try:
                rendered = fmt_eastern(created, "%Y-%m-%d %H:%M %Z")
                ok(f"fmt_eastern accepts approvals_page output: {rendered!r}")
            except Exception as e:
                fail(
                    "fmt_eastern accepts approvals_page output",
                    f"raised {type(e).__name__}: {e}",
                )
        else:
            fail(
                "approvals_page created_at is datetime",
                f"expected datetime, got {type(created).__name__}: {created!r}",
            )
except AttributeError as e:
    # The exact failure mode that motivated this regression test.
    fail(
        "approvals_page does not crash on dispatcher str created_at",
        f"AttributeError: {e}",
    )
except Exception as e:
    fail(
        "approvals_page runs to completion",
        f"{type(e).__name__}: {e}",
    )


# ── Summary ───────────────────────────────────────────────────────────────

print()
print("══════════════════════════════════════════════════")
total = PASS + FAIL
if FAIL == 0:
    print(f"  PASSED  {PASS}/{total} fmt_eastern tests")
else:
    print(f"  FAILED  {PASS} passed, {FAIL} failed — {total} total")
print("══════════════════════════════════════════════════")
sys.exit(0 if FAIL == 0 else 1)
