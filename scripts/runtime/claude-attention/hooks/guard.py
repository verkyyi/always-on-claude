#!/usr/bin/env python3
"""
PreToolUse guard for Bash commands. Runs on EVERY Bash tool call across all
Claude sessions (registered in ~/.claude/settings.json). Because this host runs
on `bypassPermissions`, this deny-list is the last line of defense for the handful
of commands that are genuinely irreversible / prod-destructive.

Contract (Claude Code hooks):
  - stdin: JSON with {tool_name, tool_input:{command,...}}
  - exit 0  -> allow
  - exit 2  -> BLOCK, stderr is shown to the model so it can course-correct
  - any error here -> we exit 0 (fail OPEN) so a guard bug never bricks every session.

This is a STARTER deny-list tuned to this repo's tripwires (master = prod truth,
prod RDS is read-only, prod k8s). Tighten/loosen the RULES below as needed.
"""
import sys, re, json

def allow():
    sys.exit(0)

def block(reason):
    sys.stderr.write(
        "⛔ BLOCKED by ~/.claude/hooks/guard.py: %s\n"
        "This command is irreversible/prod-destructive and is denied even in bypass mode.\n"
        "If it is truly intended, run it yourself in a terminal or edit the guard's RULES.\n"
        % reason
    )
    sys.exit(2)

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        allow()  # fail open

    if data.get("tool_name") != "Bash":
        allow()
    ti = data.get("tool_input") or {}
    cmd = ti.get("command", "") if isinstance(ti, dict) else ""
    if not cmd:
        allow()

    low = cmd.lower()

    # 1) Force-push that touches master/main (feature-branch force-push stays allowed).
    if re.search(r"\bgit\b", low) and re.search(r"\bpush\b", low):
        forced = re.search(r"(--force\b|--force-with-lease|(^|\s)-\w*f\w*(\s|$))", low)
        if forced and re.search(r"\b(master|main)\b", low):
            block("force-push targeting master/main (master = prod truth)")
        if re.search(r"\+[\w/]*\b(master|main)\b", low):  # +master refspec = force
            block("force refspec push to master/main")

    # 2) Write SQL against the prod RDS host (prod DB is READ-ONLY here).
    if re.search(r"rm-wz9314", low) and re.search(
        r"\b(insert|update|delete|drop|truncate|alter\s+table|create\s+table)\b", low
    ):
        block("write SQL against prod RDS host rm-wz9314... (prod DB is read-only)")

    # 3) Destructive kubectl against prod.
    if re.search(r"\bkubectl\b", low):
        if re.search(r"\bdelete\s+(namespace|ns)\b", low):
            block("kubectl delete namespace")
        if re.search(r"\bdelete\b", low) and re.search(r"\b(pv|pvc|persistentvolume(claim)?s?)\b", low):
            block("kubectl delete of a persistent volume / claim")
        if re.search(r"\b(delete|drain|cordon)\b", low) and re.search(
            r"(-n\s+prod|--namespace\s+prod|\bnamespace/prod\b|\bprod\b)", low
        ):
            block("destructive kubectl (delete/drain/cordon) against a prod namespace")

    # 4) rm -rf on filesystem root, home, or a .git directory.
    if re.search(r"\brm\b", low):
        recursive_force = (
            re.search(r"(^|\s)-\w*r\w*f\w*|\s-\w*f\w*r\w*", low)  # -rf / -fr bundled
            or (re.search(r"(^|\s)-\w*r", low) and re.search(r"(^|\s)-\w*f", low))  # -r -f
            or ("--recursive" in low and "--force" in low)
        )
        if recursive_force:
            if re.search(r"\brm\b[^|;&]*\s(/|/\*|~|~/\*|\$home|\$\{home\})(\s|$|/)", low):
                block("rm -rf targeting filesystem root or $HOME")
            if re.search(r"\.git(\s|/|$)", low):
                block("rm -rf touching a .git directory (use `git worktree remove`)")

    allow()

if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)  # never brick a session on a guard bug
