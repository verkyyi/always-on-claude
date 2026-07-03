#!/bin/sh
# gh-glance.sh — open PRs + issues for the GitHub repo of the current tmux pane.
# fzf: preview shows the PR/issue body; Enter prints the full URL and holds so
# you can cmd-click it in iTerm (works over SSH — no remote browser needed).
# Bound to `prefix + i`. Runs inside `tmux display-popup -E`.

path=$(tmux display-message -p '#{pane_current_path}')
cd "$path" 2>/dev/null || cd "$HOME" || exit 0

repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
if [ -z "$repo" ]; then
  printf 'Not inside a GitHub repo (%s)\n' "$path"; sleep 2; exit 0
fi

# rows: TYPE \t number \t url \t display    (display is what fzf shows)
prs=$(gh pr list --limit 40 \
  --json number,title,headRefName,isDraft,url,statusCheckRollup \
  -q '.[]
      | ((.statusCheckRollup // []) | map(.conclusion // .state)) as $s
      | (if   ($s | any(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT")) then "✗CI"
         elif ($s | length) == 0 then "  "
         elif ($s | all(. == "SUCCESS"))                                     then "✓CI"
         else "•CI" end) as $ci
      | "PR\t\(.number)\t\(.url)\t[\($ci)]\(if .isDraft then " draft" else "" end) #\(.number) \(.title)  «\(.headRefName)»"' \
  2>/dev/null)

iss=$(gh issue list --limit 40 --json number,title,url \
  -q '.[] | "IS\t\(.number)\t\(.url)\t🟠 #\(.number) \(.title)"' 2>/dev/null)

rows=$(printf '%s\n%s\n' "$prs" "$iss" | grep -v '^[[:space:]]*$')
if [ -z "$rows" ]; then
  printf 'No open PRs or issues in %s ✓\n' "$repo"; sleep 2; exit 0
fi

sel=$(printf '%s\n' "$rows" | fzf --with-nth=4.. --delimiter='\t' \
  --prompt="$repo > " --height=100% --border --ansi \
  --header='PRs + open issues  ·  [enter] show URL (cmd-click in iTerm)  ·  [ctrl-c] close' \
  --preview='t={1}; n={2}; if [ "$t" = PR ]; then gh pr view "$n"; else gh issue view "$n"; fi' \
  --preview-window='down,65%,wrap')

[ -z "$sel" ] && exit 0
url=$(printf '%s' "$sel" | cut -f3)

# Print the URL big and hold the popup so it stays cmd-clickable in iTerm.
clear
printf '\n  %s\n\n' "$(printf '%s' "$sel" | cut -f4-)"
printf '  \033[1;36m%s\033[0m\n\n' "$url"
# best-effort: also push it to the local clipboard via OSC 52 (iTerm supports it)
b64=$(printf '%s' "$url" | base64 | tr -d '\n')
printf '\033]52;c;%s\a' "$b64"
printf '  (cmd-click the link above — also copied to your clipboard. Press Enter to close.)'
read _dummy