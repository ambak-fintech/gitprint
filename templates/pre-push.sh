#!/bin/bash
# Gitprint — pre-push hook
# On the first push of a new branch, shows an arrow-key menu to pick the PR target.
# Options ranked by total commit count (most commits = long-lived base branch).
# Parent branch is always shown first and pre-selected.

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null) || exit 0
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
BRANCH_JSON="$ROOT/.gitprint/branch.json"

[ ! -f "$BRANCH_JSON" ] && exit 0

# Skip if already confirmed for this branch
CONFIRMED=$(node -e "
  try {
    const d = JSON.parse(require('fs').readFileSync('$BRANCH_JSON','utf8'));
    console.log(d.prTargetConfirmed === true && d.branch === '$BRANCH' ? 'true' : 'false');
  } catch { console.log('false'); }
" 2>/dev/null)
[ "$CONFIRMED" = "true" ] && exit 0

# Read parent from branch.json
PARENT=$(node -e "
  try { console.log(JSON.parse(require('fs').readFileSync('$BRANCH_JSON','utf8')).parent || ''); }
  catch { console.log(''); }
" 2>/dev/null)

BASE_CONFIG=$(git config gitprint.baseBranch 2>/dev/null || echo 'main')

# Skip if this branch is itself a base branch
for b in "$PARENT" "$BASE_CONFIG" main master; do
  [ "$BRANCH" = "$b" ] && exit 0
done

# ── Rank remote branches by total commit count ──
# Long-lived base branches (main, staging) have thousands of commits.
# Feature branches have tens. The gap is always decisive.
TOP_BRANCHES=$(
  git for-each-ref refs/remotes/origin --format='%(refname:short)' 2>/dev/null \
    | sed 's|^origin/||' \
    | grep -v "^HEAD$" \
    | grep -v "^${BRANCH}$" \
    | grep -v "^${PARENT}$" \
    | while IFS= read -r ref; do
        count=$(git rev-list --count "origin/$ref" 2>/dev/null) || continue
        printf '%s\t%s\n' "$count" "$ref"
      done \
    | sort -t$'\t' -k1 -rn \
    | awk -F'\t' '{print $2}' \
    | head -2
)

# ── Build options: parent first, then top 2 by commit count, then custom ──
OPTIONS=()
[ -n "$PARENT" ] && OPTIONS+=("$PARENT")
while IFS= read -r b; do
  [ -n "$b" ] && OPTIONS+=("$b")
done <<< "$TOP_BRANCHES"
OPTIONS+=("Enter branch name...")

OPTION_COUNT=${#OPTIONS[@]}

# ── Arrow-key interactive menu ──
render_menu() {
  local sel=$1
  for i in "${!OPTIONS[@]}"; do
    if [ "$i" -eq "$sel" ]; then
      printf "    \033[36m❯ %s\033[0m\033[K\n" "${OPTIONS[$i]}"
    else
      printf "      %s\033[K\n" "${OPTIONS[$i]}"
    fi
  done
}

run_menu() {
  local selected=0
  tput civis 2>/dev/null   # hide cursor

  render_menu "$selected"

  while true; do
    # Move cursor back up to redraw
    printf "\033[%dA" "$OPTION_COUNT"

    # Read keypress — handle escape sequences for arrow keys
    IFS= read -rsn1 key
    if [[ "$key" == $'\x1b' ]]; then
      IFS= read -rsn2 seq
      key="${key}${seq}"
    fi

    case "$key" in
      $'\x1b[A')  # Up arrow
        [ "$selected" -gt 0 ] && ((selected--))
        ;;
      $'\x1b[B')  # Down arrow
        [ "$selected" -lt $((OPTION_COUNT - 1)) ] && ((selected++))
        ;;
      '')          # Enter
        break
        ;;
      $'\x03'|q)  # Ctrl-C or q — abort push
        tput cnorm 2>/dev/null
        printf "\n  \033[2mgitprint: cancelled\033[0m\n\n"
        exit 1
        ;;
    esac

    render_menu "$selected"
  done

  tput cnorm 2>/dev/null   # restore cursor
  echo "$selected"
}

# Must redirect stdin from /dev/tty — git replaces stdin during push
exec < /dev/tty

printf "\n  \033[34mgitprint\033[0m: Where should the PR for '\033[33m%s\033[0m' target?\n\n" "$BRANCH"

SELECTED_IDX=$(run_menu)
printf "\n"

TARGET="${OPTIONS[$SELECTED_IDX]}"

# If user chose "Enter branch name..." prompt for it
if [ "$TARGET" = "Enter branch name..." ]; then
  printf "  Branch name: "
  IFS= read -r TARGET
fi

[ -z "$TARGET" ] && TARGET="${PARENT:-$BASE_CONFIG}"

# ── Persist to branch.json ──
node -e "
  const fs = require('fs');
  let d = {};
  try { d = JSON.parse(fs.readFileSync('$BRANCH_JSON', 'utf8')); } catch {}
  d.parent = process.argv[1];
  d.prTargetConfirmed = true;
  fs.writeFileSync('$BRANCH_JSON', JSON.stringify(d, null, 2) + '\n');
" "$TARGET" 2>/dev/null

printf "  \033[32mgitprint\033[0m: PR will target '\033[33m%s\033[0m' \033[32m✓\033[0m\n\n" "$TARGET"
exit 0
