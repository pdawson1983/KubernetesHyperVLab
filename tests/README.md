# AgentForge Test Suite

Four test suites covering different layers of the system.

## Suites

| Suite | File | Requires cluster | Run time |
|-------|------|-----------------|----------|
| Unit — entrypoint | `unit/test-entrypoint.sh` | No | ~2s |
| Helm templates | `helm/test-helm.py` | No | ~5s |
| Integration — dispatcher HTTP | `unit/test-dispatcher.py` | Yes | ~10s |
| Integration — web UI HTTP | `unit/test-webui.py` | Yes | ~10s |
| Behavior — end-to-end | `behavior/test-behavior.sh` | Yes | ~3 min |
| Smoke — pipeline --mock | `../scripts/pipeline-test.sh` | Yes | ~30s |

## Running

```bash
# All suites
./tests/run-all.sh

# No cluster needed (fast)
./tests/run-all.sh --unit
./tests/run-all.sh --helm

# Cluster required
./tests/run-all.sh --integration
./tests/run-all.sh --behavior
./tests/run-all.sh --smoke

# Individual suites
bash tests/unit/test-entrypoint.sh
python3 tests/helm/test-helm.py
python3 tests/unit/test-dispatcher.py
python3 tests/unit/test-webui.py
bash tests/behavior/test-behavior.sh
```

## What Each Suite Tests

### Unit — entrypoint (`test-entrypoint.sh`)
Tests `entrypoint.sh` logic in isolation using a fake NFS filesystem tree.
No container, no cluster needed.
- CLAUDE.md precedence (task-scoped wins over global)
- Skip agents detection from `task.json`
- Next-role mapping (coder→tester→reviewer→ops)
- Skip-through trigger file content and `skipped:true` flag
- Token metrics extraction from `metrics.json`
- Mock mode output path structure

### Helm templates (`test-helm.py`)
Renders the chart with `helm template` and asserts on the output.
No cluster needed, catches template regressions immediately.
- `fullnameOverride: agentforge` produces `agentforge-*` names
- No `claude-agents-claude-agents-*` duplicate names
- Per-agent `maxTurns` values (20/50/25/40/30)
- `global.maxTurns=3` overrides all agents
- `RESOURCE_PREFIX` and `APPROVAL_REQUIRED` in dispatcher
- GitHub MCP server conditional rendering
- `runAsUser: 1001` and `runAsNonRoot: true` on all 5 agents
- Postgres and Web UI conditional rendering

### Integration — dispatcher HTTP (`test-dispatcher.py`)
HTTP tests against the running dispatcher pod.
- `GET /healthz` and `/readyz` → 200
- `GET /tasks` → 200, valid JSON list
- `GET /task/<real-id>` → 200, correct task_id
- `GET /task/<nonexistent>` → 404
- `GET /pending` → 200, valid JSON list
- `POST /` with bad HMAC → 401
- `POST /` with valid HMAC → 200/202 with task_id
- `POST /approve/<nonexistent>` → 404

### Integration — web UI HTTP (`test-webui.py`)
HTTP tests against the running web UI pod.
- Dashboard, Submit, Approvals pages return 200
- Submit form has all expected fields (title, repo_url, event, context, skipAgents)
- Submit form has plain-English pipeline mode and Skip Agents checkboxes
- Task detail shows Tokens/Cost/Turns columns and Total Cost stat
- Nonexistent task returns 404

### Behavior (`test-behavior.sh`)
End-to-end tests that fire real webhook events and assert pipeline behavior.
Runs in mock mode to avoid token costs.
- **Skip agents**: submit with `skipAgents:["tester"]`; verify tester.status=skipped
  and reviewer ran successfully
- **Context CLAUDE.md**: submit with context field; verify `/memory/tasks/<id>/CLAUDE.md`
  written with correct content; verify architect log shows it was read
- **Task metadata**: verify all expected fields in task.json after dispatch

## CI Gate for Self-Improvement PRs

When the self-improvement loop opens a PR modifying `agent-base.md` or CLAUDE.md files,
the following suites must pass before merge:

1. `./tests/run-all.sh --unit` — entrypoint logic unchanged
2. `./tests/run-all.sh --helm` — no template regressions
3. `./scripts/pipeline-test.sh --mock` — full chain still works
4. `./tests/run-all.sh --behavior` — skip, context, metadata behaviors intact
