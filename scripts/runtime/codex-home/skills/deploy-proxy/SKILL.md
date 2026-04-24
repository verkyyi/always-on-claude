---
name: "deploy-proxy"
description: "Deploy the AgentFolio Cloudflare Worker proxy from the current branch, using the Cloudflare API token stored in AWS SSM at /agentfolio/cloudflare_api_token. Use when the user needs a one-off proxy deploy outside the CI workflow (e.g., testing an unmerged branch, fast-unstuck after a protocol change, verifying a preview build)."
---

# Deploy Proxy

## Codex Notes

- This is a user-confirmed deployment workflow. Keep the confirmation gate before production deploys.


Deploy AgentFolio's Cloudflare Worker (`agentfolio-chat`) from the current branch.

## Preconditions

- Current working directory is an AgentFolio checkout (has `proxy/wrangler.toml`).
- AWS CLI is authenticated as `cli_user` (account 805425385773) with read access to SSM `/agentfolio/cloudflare_api_token` in `us-east-1`.
- The branch in the current worktree contains the proxy code you want deployed (check `git log -1 -- proxy/` first if unsure).

## Steps

1. Locate the proxy directory:
   ```bash
   ROOT=$(git rev-parse --show-toplevel) && cd "$ROOT/proxy"
   ```

2. Fetch the token from SSM (never echo it):
   ```bash
   export CLOUDFLARE_API_TOKEN=$(aws ssm get-parameter \
     --region us-east-1 \
     --name /agentfolio/cloudflare_api_token \
     --with-decryption \
     --query Parameter.Value --output text)
   ```

3. Pre-flight (fast — skips on known-clean CI but worth locally):
   ```bash
   npx tsc --noEmit && npx vitest run
   ```
   If either fails, stop and report — don't deploy broken code.

4. Deploy:
   ```bash
   npx wrangler deploy
   ```

5. Smoke test the new version (sanity check that framed SSE comes back):
   ```bash
   curl -sN --max-time 10 -X POST https://agentfolio-chat.agentfolio.workers.dev/chat \
     -H "Origin: https://lianghuiyi.com" \
     -H "Content-Type: application/json" \
     -d '{"slug":"default","messages":[{"role":"user","content":"hello"}]}' \
     | head -3
   ```
   Expect `event: text` and `event: done` frames, not Anthropic-native `content_block_delta`.

6. Report the deployed Version ID (from the wrangler output) and whether the smoke test passed.

## Safety

- Deploying from a non-merged branch OVERWRITES production. State the branch name and commit SHA before step 4 and ask for confirmation unless the user already indicated they want to deploy from this exact branch.
- Never commit the `CLOUDFLARE_API_TOKEN`, an `.env` file, or `.dev.vars` containing it. The proxy's `.gitignore` already excludes `.dev.vars` but verify.
- Never run this from `main` without confirming the GitHub Actions `proxy.yml` workflow hasn't already deployed the same code (check `gh run list --workflow proxy.yml -L 3`).
