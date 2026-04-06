#!/bin/bash
# Gitprint — Git Post-Checkout Hook
# Writes .gitprint/branch.json with parent branch info when a NEW branch is created.
# This file is read by the gitprint GitHub Action to determine the PR target branch.

PREV_REF="$1"
NEW_REF="$2"
BRANCH_FLAG="$3"

# Only act on branch switches (not file checkouts)
[ "$BRANCH_FLAG" = "1" ] || exit 0

# Get current branch name (exit on detached HEAD)
CURRENT=$(git symbolic-ref --short HEAD 2>/dev/null) || exit 0

# Skip if branch.json already tracks this branch (not a new branch)
BRANCH_JSON=".gitprint/branch.json"
if [ -f "$BRANCH_JSON" ]; then
  EXISTING=$(node -e "try{console.log(JSON.parse(require('fs').readFileSync('$BRANCH_JSON','utf8')).branch||'')}catch{console.log('')}" 2>/dev/null)
  [ "$EXISTING" = "$CURRENT" ] && exit 0
fi

# Determine the branch we came FROM (the parent)
# PREV_REF is the commit SHA we were on before checkout
# Resolve it to a branch name using only local branch refs
PARENT=$(git name-rev --name-only --refs='refs/heads/*' "$PREV_REF" 2>/dev/null | sed 's/~[0-9]*$//')

# If name-rev fails or returns garbage, skip
[ -z "$PARENT" ] && exit 0
[ "$PARENT" = "undefined" ] && exit 0
[ "$PARENT" = "HEAD" ] && exit 0

# Don't overwrite if parent = current (not a new branch)
[ "$PARENT" = "$CURRENT" ] && exit 0

# Write .gitprint/branch.json
mkdir -p .gitprint
node -e "
  const fs = require('fs');
  const data = {
    branch: process.argv[1],
    parent: process.argv[2],
    created: new Date().toISOString(),
  };
  fs.writeFileSync('.gitprint/branch.json', JSON.stringify(data, null, 2) + '\n');
" "$CURRENT" "$PARENT" 2>/dev/null

exit 0
