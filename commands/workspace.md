# Workspace Manager

You are helping the user manage git worktrees from inside a running Claude session.

## Steps

1. Run this command to discover all repos and worktrees:
   ```bash
   bash ~/dev-env/worktree-helper.sh list-repos
   ```

2. Present the results clearly, showing:
   - **Repos** with their current branch
   - **Worktrees** with their branch (marked as worktree)

3. Ask the user what they'd like to do:

   - **Create a new worktree** — ask which repo and branch name, then run:
     ```bash
     bash ~/dev-env/worktree-helper.sh create <repo-path> <branch-name>
     ```
   - **Delete a worktree** — confirm with the user first, then run:
     ```bash
     bash ~/dev-env/worktree-helper.sh remove <worktree-path>
     ```
   - **Show info** — display current workspace (`pwd`), branch (`git branch --show-current`), and status (`git status --short`)

4. After creating or deleting a worktree, remind the user:

   > To switch to this workspace, start a new session — open a new SSH connection or use `tmux new-window`.
   > Claude's working directory is set at launch and cannot change mid-session.
