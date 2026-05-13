# ADR-016: Test Tooling Using Built-in Tools Over External Frameworks

**Date:** 2026-05-12
**Status:** accepted

## Context

Building the test suite required choosing test tooling for four layers:
bash logic, Helm templates, HTTP endpoints, and end-to-end behavior.
Options with external dependencies (BATS, pytest, helm-unittest plugin) were
available but not pre-installed. Installing them adds maintenance burden and
makes the test suite harder to run on a fresh machine.

Available without installation:
- `bash` — for shell unit tests and behavior scripts
- `python3` + `httpx` (already present from web UI dependencies) — for HTTP tests
- `helm template` — built into helm, renders charts without a cluster
- `python3` stdlib — regex, subprocess, assertions

## Decision

Build all four test layers using only tools already present:

1. **Entrypoint unit tests** — pure bash with a fake NFS filesystem; no bats
2. **Helm template tests** — `helm template` piped to Python regex assertions; no helm-unittest
3. **HTTP tests** — Python + httpx; no pytest (tests written as standalone scripts)
4. **Behavior tests** — bash + kubectl + curl; no framework

All suites are standalone scripts that print `PASS/FAIL` lines and exit non-zero on failure, making them composable with `&&` and easy to read in CI logs.

## Consequences

- **Easier:** Any machine with helm + python3 + httpx can run the full suite. No `pip install`, `npm install`, or plugin installs.
- **Easier:** Tests are readable bash/Python — no framework syntax to learn.
- **Harder:** No test discovery, no parametrize, no fixtures library. Test isolation is manual (setup/teardown in each test function).
- **Watch for:** The `(( N++ ))` bash arithmetic idiom returns exit code 1 when N=0; use `N=$(( N + 1 ))` instead in `&&...||` chains. This was the only non-obvious gotcha found during implementation.
- **Future:** If the suite grows significantly, pytest could be adopted for the Python tests without breaking the bash tests. The `run-all.sh` interface stays the same.
