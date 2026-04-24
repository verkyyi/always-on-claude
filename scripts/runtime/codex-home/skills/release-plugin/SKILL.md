---
name: "release-plugin"
description: "Cut a new version of a Claude Code plugin in the current working directory \u2014 bump .claude-plugin/plugin.json, update README version references, commit, tag, push, and create a GitHub Release with notes summarizing commits since the last tag. Use when shipping a plugin update so end-user auto-update paths (claude-plugins.dev, ClaudePluginHub, marketplace listings) pick up the new version. Typical trigger: user says \"release the plugin\", \"ship a new version\", \"cut v0.x.y\", \"tag a release\"."
---

# Release Plugin

## Codex Notes

- This skill still targets Claude Code plugin repos that ship from `.claude-plugin/plugin.json`.


Release the Claude Code plugin in `$CWD` as a new semver-tagged version. Picks up all changes since the last tag into one release.

## Preconditions

- CWD is a Claude Code plugin repo — has `.claude-plugin/plugin.json` with a `"version"` field.
- CWD is a git repo with a clean working tree (`git status --porcelain` empty).
- Current branch is `main` (or explicitly confirmed by user).
- `gh` CLI authenticated with write access + `repo` scope.
- All desired commits are already merged to the branch being released.

## Flow

### 1. Snapshot the state

- Read `.claude-plugin/plugin.json` — capture current `"version"` and `"name"`.
- Get the latest tag: `git tag --sort=-version:refname | head -1`.
- List commits since that tag: `git log <last-tag>..HEAD --oneline`.
- If no commits since last tag → stop. No release needed.
- If no tags at all → this is the first release; treat the next version as the initial tag.

### 2. Decide the new version

Scan the commit subjects. Pick a bump per semver:

- **Patch** (`x.y.Z+1`) — bug fixes, doc updates, internal tooling, attribution. No API/contract changes.
- **Minor** (`x.Y+1.0`) — new skills, new commands, new catalog entries, additive features. No breaking changes.
- **Major** (`X+1.0.0`) — breaking changes to skill names / slash commands / frontmatter contracts.

Default bump: patch unless user asks otherwise or commits reveal a new feature. State the chosen bump + reasoning, give the user a chance to override before proceeding.

### 3. Apply the version bump

- Edit `.claude-plugin/plugin.json`: `"version": "<new>"`.
- Check README for any version-referencing line (usually a `Status:` or `What's new in` header). If found, update to the new version — many plugin CIs enforce manifest↔README alignment and will fail invariant checks otherwise.
- Skim README's intro/"What's new" section. If commits include user-visible changes, ask the user whether to append a "What's new in v<new>" block listing them. Do not invent features — the list must be derivable from the commit log.

### 4. Commit + tag + push

```bash
git add .claude-plugin/plugin.json README.md
git commit -m "Ship v<new>: <one-line summary>"
git push origin main

git tag -a v<new> -m "v<new>: <one-line summary>"
git push origin v<new>
```

Commit message body should reference the commit range (e.g., "N commits since v<old>") and the top 3-5 user-visible changes by short-sha.

### 5. Create the GitHub Release

Use `gh release create v<new>` with a structured body:

- **Headline**: one-line elevator for the release
- **User-visible improvements** — group by area: Skills / Catalog / Metadata. Reference commits by short-sha in parens. Skip internal-only changes (test infra, CI plumbing) from this section.
- **Engineering additions (no user impact)** — mention briefly so contributors know what landed
- **Upgrade** — one paragraph on how end users pick up the release (usually: re-install via the skill, or trust auto-update to crawl)
- **Acknowledgments** — only if upstream work was meaningfully incorporated this release

Body derived from the commit log, not invented. Use `gh release create v<new> --title "..." --notes "..."` with a heredoc.

### 6. Confirm end-state

- `gh release view v<new>` shows the release is live.
- `git log --oneline | head -5` shows the tag-bump commit on main.
- Optional: note in the summary that marketplaces (claude-plugins.dev, ClaudePluginHub) will re-crawl on their own cadence and push the update to installed users.

## Hard rules

- **Never release from a dirty working tree.** Even untracked files unrelated to the plugin can signal unfinished work. If `git status --porcelain` is non-empty, stop and ask.
- **Never invent features** in the release notes. Every bullet must trace to a committed change (cite short-sha when possible).
- **Never skip the version bump in `plugin.json`.** That's the one file end-user auto-update paths actually read; without it, re-crawling marketplaces won't push the update to installed plugins.
- **Never push a tag without a matching commit on main first.** A tag on a commit that's not yet pushed creates a "phantom" release that downstream tooling can't resolve.
- **Never force-push or retag.** If something went wrong, cut a new patch version (v0.2.1 → v0.2.2). Tags are immutable for downstream trust.
- **Never commit or push without explicit user confirmation** when the diff is more than the version bump + README alignment. Releases are user-visible; the user should explicitly OK anything substantive.

## When NOT to use

- Plugin is in active development with no logical release point (wait).
- Commits are all internal tooling with no user-visible change (wait — no signal to publish).
- Repo is not a Claude Code plugin (no `.claude-plugin/plugin.json`).
- User wants to fix a bad release — see "Hard rules": cut a new version instead of mutating the broken one.

## Related patterns

- **`v0.x.0` minor bumps** typically add new catalog entries, new skills, or new agent-team roles. Reserve for substantive additions.
- **`v0.x.y+1` patch bumps** are the common case during polish iterations — doc fixes, prompt tuning, dependency pins, attribution.
- **Plugins with a `test-invariants.sh` that enforces manifest↔README alignment** (like github-agent-runner) require the README bump in step 3 or the invariant test fails in CI after the tag commit.
