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
  - any error here -> exit 0 (fail OPEN) so a guard bug never bricks every session.

FALSE-POSITIVE DISCIPLINE: the command is split into statement SEGMENTS on
; \n && || | before matching, so tokens from a commit message or an unrelated
statement can't combine across segments (e.g. "-rf" in a message + "master"
elsewhere). Rules also match the git SUBCOMMAND (a real `git push`), not just the
word "push" appearing anywhere. Tune the RULES below as needed.
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

# A short-option bundle (e.g. -rf, -Rf) containing letter `c`; anchored so only
# real flag tokens match and a trailing non-letter (e.g. -print0) does NOT.
def _has_short_flag(seg, c):
    return re.search(r"(?:^|\s)-[a-zA-Z]*" + c + r"[a-zA-Z]*(?=\s|$)", seg) is not None

# The segment's COMMAND (after optional `sudo` / `VAR=val` prefixes) is `name`.
# Anchoring here means a dangerous word inside a message, an echo, or another
# command's arguments cannot trigger a rule.
def _cmd_is(seg, name):
    return re.match(r"\s*(?:sudo\s+|\w+=\S+\s+)*" + name + r"\b", seg) is not None

def check_segment(low):
    # 1) Force-push touching master/main — must be an actual `git push` command.
    if re.match(r"\s*(?:sudo\s+|\w+=\S+\s+)*git\b(?:\s+(?:-\S+|\S+=\S+))*\s+push\b", low):
        forced = (
            "--force" in low
            or "--force-with-lease" in low
            or _has_short_flag(low, "f")                    # -f / -fv etc.
            or re.search(r"\+\S*\b(?:master|main)\b", low)  # +master refspec
        )
        if forced and re.search(r"\b(?:master|main)\b", low):
            block("force-push targeting master/main (master = prod truth)")

    # 2) Write SQL against the prod RDS host (host + write keyword; prod DB is read-only).
    if re.search(r"rm-wz9314", low) and re.search(
        r"\b(?:insert|update|delete|drop|truncate|alter\s+table|create\s+table)\b", low
    ):
        block("write SQL against prod RDS host rm-wz9314... (prod DB is read-only)")

    # 3) Destructive kubectl against prod — must be a kubectl command.
    if _cmd_is(low, "kubectl"):
        if re.search(r"\bdelete\s+(?:namespace|ns)\b", low):
            block("kubectl delete namespace")
        if re.search(r"\bdelete\b", low) and re.search(r"\b(?:pv|pvc|persistentvolume(?:claim)?s?)\b", low):
            block("kubectl delete of a persistent volume / claim")
        if re.search(r"\b(?:delete|drain|cordon)\b", low) and re.search(
            r"(?:-n\s+prod|--namespace\s+prod|\bnamespace/prod\b|\bprod\b)", low
        ):
            block("destructive kubectl (delete/drain/cordon) against a prod namespace")

    # 4) rm -rf on root/home/.git — must be an `rm` command (so `git rm` is exempt),
    #    with real recursive AND force flags and a bare dangerous target.
    if _cmd_is(low, "rm"):
        recursive = ("--recursive" in low) or _has_short_flag(low, "r")
        force     = ("--force" in low)     or _has_short_flag(low, "f")
        if recursive and force:
            # bare dangerous target as its own arg — tolerates a trailing slash,
            # a `*`, and surrounding quotes ("/", "$HOME", ~/); but NOT a subpath
            # (/usr/..., $HOME/.cache) which stays allowed.
            if re.search(r"(?:^|\s|[\x22\x27])(?:/|~|\$home|\$\{home\})/?\*?[\x22\x27]?(?:\s|$)", low):
                block("rm -rf targeting filesystem root or $HOME")
            if re.search(r"(?:^|\s)\S*\.git(?:\s|/|$)", low):
                block("rm -rf touching a .git directory (use `git worktree remove`)")

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

    # split into statement segments so unrelated tokens can't combine
    for seg in re.split(r"&&|\|\||\||;|\n", cmd):
        seg = seg.strip()
        if seg:
            check_segment(seg.lower())
    allow()

if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)  # never brick a session on a guard bug
