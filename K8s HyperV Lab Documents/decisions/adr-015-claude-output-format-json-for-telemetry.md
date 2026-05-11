# ADR-015: Use --output-format json for Token and Cost Telemetry

**Date:** 2026-05-11
**Status:** accepted

## Context

Token consumption tracking required capturing `tokens_input`, `tokens_output`,
`cache_read_input_tokens`, `cache_creation_input_tokens`, `total_cost_usd`, and
`num_turns` per agent run. Two approaches were considered:

1. **Parse the text output log** — grep/regex the Claude Code output for token
   counts. Claude Code's default `--print` mode does not include a structured
   usage block in its text output, making this fragile and version-dependent.

2. **Use `--output-format json`** — Claude Code's `--print --output-format json`
   emits a single JSON object at completion containing `usage`, `modelUsage`,
   `total_cost_usd`, `num_turns`, and the `result` text. Structured, stable,
   no parsing.

## Decision

Switch all agent invocations to `--output-format json`. The JSON is captured to
a temp file, then:
- `result` text is extracted and written to the standard output log (same UX
  as before for `kubectl logs` and log file readers)
- Full JSON is saved as `logs/<role>-metrics.json`
- `_record_completion` reads `metrics.json` and writes token/cost/turns fields
  into `task.json`, which the observer imports to Postgres

## Consequences

- **Easier:** All token/cost/turns data available with zero parsing; survives
  Claude Code version upgrades as long as the JSON schema is stable.
- **Easier:** The `usage` object includes `cache_read_input_tokens` and
  `cache_creation_input_tokens` — useful for understanding prompt caching
  efficiency per agent.
- **Harder:** Agent output is no longer streamed to `kubectl logs` in real time;
  it appears as a single block when Claude finishes. The entrypoint log still
  streams, so startup/error messages are immediate.
- **Watch for:** If Claude Code exits with a non-JSON error (e.g. auth failure,
  timeout), the temp file contains plain text. The extraction step handles this
  with a try/except, writing raw content to the output log as a fallback.
- **Note:** `--output-format json` requires `--print` — it only works in
  non-interactive mode, which is the agent's operating mode.
