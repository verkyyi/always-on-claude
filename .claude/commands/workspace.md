# Workspace Manager

You are helping the user manage git workspaces. This runs on the **host** — `~/projects` is bind-mounted into the container, so changes are visible to both sides.

## Steps

1. Run this single command to check environment and discover repos:
   ```bash
   if ! test -f ~/dev-env/.provisioned; then echo "NOT_PROVISIONED"; else bash ~/dev-env/scripts/runtime/worktree-helper.sh list-repos; fi
   ```

   If the output is `NOT_PROVISIONED`, tell the user:
   "This command is only available on a provisioned workspace. SSH into your instance and use [m] to manage workspaces."
   Then stop.

2. Present the results clearly, showing:
   - **Repos** with their current branch
   - **Worktrees** with their branch (marked as worktree)

3. Ask the user what they'd like to do:

   - **Clone a repo** — ask for the git URL, then run:
     ```bash
     git clone <url> ~/projects/<repo-name>
     ```
     Use the repo name from the URL (e.g., `https://github.com/user/my-app.git` → `~/projects/my-app`). If the directory already exists, tell the user.

   - **Create a new worktree** — ask which repo and branch name, then run:
     ```bash
     bash ~/dev-env/scripts/runtime/worktree-helper.sh create <repo-path> <branch-name>
     ```

   - **Delete a worktree** — confirm with the user first, then run:
     ```bash
     bash ~/dev-env/scripts/runtime/worktree-helper.sh remove <worktree-path>
     ```

   - **Show info** — display current workspace (`pwd`), branch (`git branch --show-current`), and status (`git status --short`)

4. After cloning, creating, or deleting a workspace, remind the user:

   > Your new repo will appear in the login menu next time you SSH in.
   > To switch now: detach from tmux (prefix + d), then reconnect via SSH.
