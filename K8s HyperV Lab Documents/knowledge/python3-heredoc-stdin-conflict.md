# python3 Heredoc + Pipe Stdin Conflict

**Date:** 2026-05-08

## Symptoms

A bash script pipes data to `python3` via a heredoc pattern and the python script
tries to read that piped data from `sys.stdin`, but always gets empty input (EOF),
causing `json.JSONDecodeError: Expecting value: line 1 column 1 (char 0)`.

The failing pattern:

```bash
result=$(kubectl get pods -o json 2>/dev/null | \
  python3 - "$arg" << 'PYEOF'
import json, sys
data = json.load(sys.stdin)   # always gets EOF — why?
PYEOF
)
```

## Root Cause

`python3 -` means "read the Python **script** from stdin". The heredoc (`<< 'PYEOF'`)
redirects stdin to a temporary file containing the heredoc content. In bash, stdin
redirections override pipe connections — the heredoc wins.

Result: python3 reads the heredoc content as its script (correct), but when the
script calls `json.load(sys.stdin)`, stdin is the heredoc file descriptor which has
already been fully read and is now at EOF. The kubectl pipe output is connected to
python3's stdin by the pipe, but the heredoc redirection overrides it, so kubectl's
output goes nowhere (broken pipe).

This is not a bug in bash or python3 — it is the defined behaviour of stdin
redirections in shell pipelines. The pipe and the heredoc both try to be stdin;
the heredoc wins because it is specified last in the command.

## Fix

Write the Python script to a named temporary file. With the script in a file,
stdin is free to receive the piped data:

```bash
# Create filter script once (outside the poll loop for efficiency)
_FILTER=$(mktemp /tmp/pod-filter-XXXXXX.py)
cat > "$_FILTER" << 'PYEOF'
import json, sys
try:
    data = json.load(sys.stdin)   # receives kubectl pipe output correctly
except Exception:
    print("Pending|"); sys.exit(0)
# ... rest of script
PYEOF

# Use the file — stdin is now the kubectl pipe
result=$(kubectl get pods -o json 2>/dev/null | python3 "$_FILTER" "$arg")

rm -f "$_FILTER"   # clean up
```

## Prevention

- Never combine `python3 -` (script from stdin) with a pipeline that also needs
  to send data to stdin. Pick one: either use `python3 - << HEREDOC` with no pipe,
  or use `python3 /path/to/script.py` and pipe freely.
- When scripting in bash, if you need both a dynamic script AND piped input, always
  write the script to a temp file first.
- `python3 -c "..."` is an alternative for short scripts — the script is passed as a
  command-line argument, leaving stdin free for the pipe. But multi-line scripts
  become unwieldy as `-c` arguments.
