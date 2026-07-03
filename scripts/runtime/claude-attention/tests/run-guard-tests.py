#!/usr/bin/env python3
"""Run guard.py against guard-cases.json (the sibling ../hooks/guard.py).

Each case is ["BLOCK"|"ALLOW", command]. BLOCK expects exit 2, ALLOW expects 0.
Exits non-zero if any case disagrees — usable as a CI/pre-commit check.

To add a case: append a ["BLOCK"|"ALLOW", "the command"] pair to guard-cases.json
and re-run:  python3 run-guard-tests.py
"""
import json, subprocess, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "..", "hooks", "guard.py")
CASES = json.load(open(os.path.join(HERE, "guard-cases.json")))

ok = bad = 0
for want, cmd in CASES:
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}})
    r = subprocess.run([sys.executable, GUARD], input=payload, capture_output=True, text=True)
    got = "BLOCK" if r.returncode == 2 else "ALLOW"
    passed = got == want
    ok += passed
    bad += not passed
    if not passed:
        print(f"FAIL want={want:5} got={got:5}  {cmd.replace(chr(10), '  ')[:70]}")

print(f"{ok} passed, {bad} failed")
sys.exit(1 if bad else 0)
