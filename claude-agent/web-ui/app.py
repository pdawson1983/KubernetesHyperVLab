import hmac, hashlib, json, os
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import asyncpg
import httpx
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

PGHOST     = os.getenv("PGHOST", "agentforge-postgres.agentforge.svc.cluster.local")
PGPORT     = int(os.getenv("PGPORT", "5432"))
PGDATABASE = os.getenv("PGDATABASE", "agentforge")
PGUSER     = os.getenv("PGUSER", "agentforge")
PGPASSWORD = os.getenv("PGPASSWORD", "")
WEBHOOK_URL     = os.getenv("WEBHOOK_URL", "http://agentforge-webhook.agentforge.svc.cluster.local:8080")
WEBHOOK_SECRET  = os.getenv("WEBHOOK_SECRET", "").encode()

db: asyncpg.Pool | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global db
    for attempt in range(10):
        try:
            db = await asyncpg.create_pool(
                host=PGHOST, port=PGPORT, database=PGDATABASE,
                user=PGUSER, password=PGPASSWORD, min_size=1, max_size=5,
            )
            print(f"[webui] connected to Postgres", flush=True)
            break
        except Exception as e:
            print(f"[webui] waiting for Postgres ({attempt+1}/10): {e}", flush=True)
            import asyncio; await asyncio.sleep(5)
    yield
    if db:
        await db.close()


app = FastAPI(lifespan=lifespan)
templates = Jinja2Templates(directory="templates")


def sign(payload_bytes: bytes) -> str:
    if not WEBHOOK_SECRET:
        return ""
    return "sha256=" + hmac.new(WEBHOOK_SECRET, payload_bytes, hashlib.sha256).hexdigest()


def fmt_cost(usd):
    if not usd:
        return "—"
    if usd < 0.001:
        return f"${usd:.4f}"
    return f"${usd:.3f}"


def fmt_tokens(n):
    if not n:
        return "—"
    if n >= 1000:
        return f"{n/1000:.1f}k"
    return str(n)


def fmt_duration(secs):
    if secs is None:
        return "—"
    if secs == 0:
        return "< 1s"
    if secs < 60:
        return f"{secs}s"
    return f"{secs // 60}m {secs % 60}s"


# ── Dashboard ──────────────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request):
    rows = await db.fetch("""
        SELECT r.task_id, r.title, r.repo_url, r.event, r.status,
               r.created_at, r.duration_seconds, r.failed_agent,
               COALESCE(SUM(a.cost_usd), 0)       AS total_cost_usd,
               COALESCE(SUM(a.tokens_input), 0)    AS total_tokens_in,
               COALESCE(SUM(a.tokens_output), 0)   AS total_tokens_out,
               json_agg(
                   json_build_object('role', a.role, 'status', a.status)
                   ORDER BY a.started_at
               ) FILTER (WHERE a.role IS NOT NULL) AS agents
        FROM pipeline_runs r
        LEFT JOIN agent_runs a ON a.task_id = r.task_id
        GROUP BY r.task_id, r.title, r.repo_url, r.event, r.status,
                 r.created_at, r.duration_seconds, r.failed_agent
        ORDER BY r.created_at DESC
        LIMIT 30
    """)
    tasks = []
    for r in rows:
        t = dict(r)
        t["agents"] = json.loads(t["agents"]) if t["agents"] else []
        t["duration_fmt"] = fmt_duration(t["duration_seconds"])
        t["cost_fmt"] = fmt_cost(float(t["total_cost_usd"] or 0))
        t["tokens_fmt"] = fmt_tokens((t["total_tokens_in"] or 0) + (t["total_tokens_out"] or 0))
        tasks.append(t)
    return templates.TemplateResponse("dashboard.html", {"request": request, "tasks": tasks})


# ── Task detail ────────────────────────────────────────────────────────────────

@app.get("/tasks/{task_id}", response_class=HTMLResponse)
async def task_detail(request: Request, task_id: str):
    run = await db.fetchrow("SELECT * FROM pipeline_runs WHERE task_id=$1", task_id)
    agent_list = []
    live = False  # whether data came from live NFS rather than Postgres

    if run:
        run = dict(run)
        run["duration_fmt"] = fmt_duration(run.get("duration_seconds"))
        db_agents = await db.fetch(
            "SELECT * FROM agent_runs WHERE task_id=$1 ORDER BY started_at", task_id
        )
        total_cost = 0.0
        for a in db_agents:
            d = dict(a)
            d["duration_fmt"] = fmt_duration(d.get("duration_seconds"))
            d["cost_fmt"] = fmt_cost(float(d.get("cost_usd") or 0))
            d["tokens_in_fmt"] = fmt_tokens(d.get("tokens_input") or 0)
            d["tokens_out_fmt"] = fmt_tokens(d.get("tokens_output") or 0)
            total_cost += float(d.get("cost_usd") or 0)
            agent_list.append(d)
        run["total_cost_fmt"] = fmt_cost(total_cost)
    else:
        # Task still running — read live from dispatcher NFS proxy
        live = True
        try:
            async with httpx.AsyncClient() as client:
                resp = await client.get(f"{WEBHOOK_URL}/task/{task_id}", timeout=5)
            if resp.status_code != 200:
                return HTMLResponse("Task not found", status_code=404)
            data = resp.json()

            def _dt(s):
                if not s:
                    return None
                try:
                    return datetime.fromisoformat(s.replace("Z", "+00:00"))
                except Exception:
                    return None

            run = {
                "task_id": task_id,
                "title":    data.get("title", task_id),
                "repo_url": data.get("repo_url", ""),
                "event":    data.get("event", ""),
                "status":   data.get("status", "running"),
                "created_at":  _dt(data.get("created_at")),
                "completed_at": _dt(data.get("completed_at")),
                "duration_seconds": data.get("duration_seconds"),
                "failed_agent": data.get("failed_agent", ""),
                "duration_fmt": fmt_duration(data.get("duration_seconds")),
            }
            for role, a in data.get("agents", {}).items():
                agent_list.append({
                    "role":             role,
                    "status":           a.get("status", "running"),
                    "duration_seconds": a.get("duration_seconds"),
                    "duration_fmt":     fmt_duration(a.get("duration_seconds")),
                    "exit_code":        a.get("exit_code"),
                    "log_path":         a.get("log"),
                    "started_at":       _dt(a.get("started_at")),
                    "cost_fmt":         fmt_cost(float(a.get("cost_usd") or 0)),
                    "tokens_in_fmt":    fmt_tokens(a.get("tokens_input") or 0),
                    "tokens_out_fmt":   fmt_tokens(a.get("tokens_output") or 0),
                })
            run["total_cost_fmt"] = "—"
            agent_list.sort(key=lambda x: x.get("started_at") or datetime.min.replace(tzinfo=timezone.utc))
        except Exception as e:
            return HTMLResponse(f"Task not found ({e})", status_code=404)

    return templates.TemplateResponse("task.html", {
        "request": request, "run": run, "agents": agent_list, "live": live,
    })


# ── Submit task ────────────────────────────────────────────────────────────────

@app.get("/submit", response_class=HTMLResponse)
async def submit_form(request: Request):
    return templates.TemplateResponse("submit.html", {"request": request, "error": None})


@app.post("/submit")
async def submit_task(
    request: Request,
    title: str = Form(...),
    repo_url: str = Form(""),
    event: str = Form("issue.opened"),
    context: str = Form(""),
):
    payload = {"event": event, "title": title}
    if repo_url.strip():
        payload["repoUrl"] = repo_url.strip()
    if context.strip():
        payload["context"] = context.strip()
    payload_bytes = json.dumps(payload).encode()
    sig = sign(payload_bytes)
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.post(
                WEBHOOK_URL,
                content=payload_bytes,
                headers={
                    "Content-Type": "application/json",
                    "X-Event-Type": event,
                    "X-Hub-Signature-256": sig,
                },
                timeout=10,
            )
        data = resp.json()
        task_id = data.get("task_id") or data.get("awaiting_approval")
        if task_id:
            return RedirectResponse(f"/tasks/{task_id}", status_code=303)
    except Exception as e:
        return templates.TemplateResponse("submit.html", {
            "request": request, "error": str(e)
        })
    return RedirectResponse("/", status_code=303)


# ── Approvals ──────────────────────────────────────────────────────────────────

@app.get("/approvals", response_class=HTMLResponse)
async def approvals_page(request: Request):
    pending = []
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.get(f"{WEBHOOK_URL}/pending", timeout=5)
            if resp.status_code == 200:
                pending = resp.json()
    except Exception as e:
        print(f"[webui] could not fetch pending approvals: {e}", flush=True)

    # Enrich with task titles from Postgres
    if pending:
        ids = [p["task_id"] for p in pending]
        rows = await db.fetch(
            "SELECT task_id, title, repo_url FROM pipeline_runs WHERE task_id = ANY($1)", ids
        )
        meta = {r["task_id"]: dict(r) for r in rows}
        for p in pending:
            p.update(meta.get(p["task_id"], {}))

    return templates.TemplateResponse("approvals.html", {
        "request": request, "pending": pending
    })


@app.post("/approvals/{task_id}/approve")
async def approve_task(task_id: str):
    try:
        async with httpx.AsyncClient() as client:
            await client.post(f"{WEBHOOK_URL}/approve/{task_id}", timeout=10)
    except Exception as e:
        return HTMLResponse(f"Approval failed: {e}", status_code=500)
    return RedirectResponse("/approvals", status_code=303)
