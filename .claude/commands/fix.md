# Fix (mobile-friendly)

Find failing tests, fix them, and commit. Minimize back-and-forth — act autonomously.

## Steps

1. Detect the test framework and run tests:

   ```bash
   if [[ -f package.json ]]; then
     echo "node"
     cat package.json | grep -E '"test"' || echo "no test script"
   elif [[ -f Makefile ]]; then
     echo "make"
     grep -E '^test:' Makefile || echo "no test target"
   elif [[ -f pytest.ini ]] || [[ -f setup.py ]] || [[ -f pyproject.toml ]]; then
     echo "python"
   else
     echo "unknown"
   fi
   ```

2. Run the tests and capture output:
   - Node: `npm test 2>&1`
   - Python: `pytest 2>&1`
   - Make: `make test 2>&1`
   - Other: ask the user what command runs tests

3. If tests pass, report "All tests passing" and stop.

4. If tests fail:
   - Identify which tests failed and why
   - Read the relevant source files
   - Fix the issues
   - Re-run the tests to confirm the fix

5. Once tests pass, stage only the files you changed and commit with a descriptive message explaining what was actually fixed.

6. Report what was fixed in 1-2 sentences.

## Important

- Run tests first — don't fix what isn't broken
- Fix and re-run in a loop until tests pass (max 3 attempts)
- If you can't fix it after 3 attempts, report what's wrong and stop
- Keep the commit message descriptive of what was actually fixed
