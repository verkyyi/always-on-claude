# Workspace Manager

You are helping the user manage git workspaces from inside a running Claude session.

## Steps

1. Run this command to discover all repos and worktrees:
   ```bash
   bash ~/dev-env/scripts/runtime/worktree-helper.sh list-repos
   ```

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

   > To switch to this workspace, start a new session — open a new SSH connection or use `tmux new-window`.
   > Claude's working directory is set at launch and cannot change mid-session.
