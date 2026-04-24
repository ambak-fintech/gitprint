#!/bin/bash
# Gitprint — AfterTool Hook (Gemini CLI)
# Fires after every Gemini tool call. Writes active session marker
# so the post-commit hook knows where to find the current transcript.

INPUT=$(cat)

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE_HELPER="$REPO_ROOT/.github/hooks/gitprint-state.js"

node - "$STATE_HELPER" "$REPO_ROOT" "$GIT_DIR" "$INPUT" <<'NODEEOF'
const state = require(process.argv[2]);
const context = state.resolveRepoStateContext({ cwd: process.argv[3], gitDir: process.argv[4], env: process.env });
const activeFile = state.resolveToolStatePaths(context, 'gemini').activeFile;
const input = process.argv[5] || '';

try {
  const { transcript_path, session_id, cwd } = JSON.parse(input);
  if (transcript_path) {
    state.writeJsonAtomic(activeFile, { transcript_path, session_id, cwd, updated: new Date().toISOString() });
  }
} catch {}
NODEEOF

exit 0
