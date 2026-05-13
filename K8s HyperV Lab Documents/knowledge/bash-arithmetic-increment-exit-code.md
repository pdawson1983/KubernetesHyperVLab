# Bash Arithmetic Increment Returns Exit Code 1 When Value is Zero

**Date:** 2026-05-12

## Symptoms

A bash test script produces both PASS and FAIL output for the same assertion:

```
  PASS  task-scoped CLAUDE.md wins over global
  FAIL  task-scoped CLAUDE.md wins over global (got: task context)
```

The condition was true (it passed), but the fail branch also fired.

## Root Cause

The pattern `[ condition ] && pass_func || fail_func` relies on `pass_func`
returning exit code 0. If `pass_func` returns non-zero, the `||` fires
`fail_func` even though the condition was true.

The `pass_func` contained `(( PASS++ ))`. In bash, `(( expression ))` returns
exit code 1 when the expression evaluates to 0 (numeric false). When `PASS=0`,
`(( PASS++ ))` evaluates the **old value** (0) after incrementing — so the
expression result is 0, and the command returns exit code 1.

```bash
PASS=0
(( PASS++ ))  # evaluates to old value 0 → exit code 1 (!)
echo $?       # 1

PASS=1
(( PASS++ ))  # evaluates to old value 1 → exit code 0
echo $?       # 0
```

## Fix

Use addition assignment instead of post-increment:

```bash
# Bad — exit code 1 on first call (PASS=0)
pass() { echo "  PASS  $1"; (( PASS++ )); }

# Good — always returns 0
pass() { echo "  PASS  $1"; PASS=$(( PASS + 1 )); }

# Also good — pre-increment evaluates to new value
pass() { echo "  PASS  $1"; (( ++PASS )); }
```

## Prevention

Never use `(( N++ ))` as the last command in a function or in an `&&...||`
chain when N could be 0. Use `N=$(( N + 1 ))` for counter increments in
shell functions that need to return exit code 0.
