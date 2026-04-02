#!/bin/bash
# Gitprint — PostToolUse Hook (Claude Code)
# Fires after every tool call. Writes active session marker
# so the post-commit hook knows where to find the transcript.
# Only acts on file-modifying tools to stay fast (< 50ms).

INPUT=$(cat)

# Fast filter: only track file-modifying tools
TOOL=$(echo "$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try { console.log(JSON.parse(d).tool_name||''); }
    catch(e) { console.log(''); }
  });
")

case "$TOOL" in
  Edit|Write|MultiEdit|str_replace|str_replace_editor|create|file_write|edit) ;;
  *) exit 0 ;;
esac

# Find .git directory
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0

# Write active session marker (transcript_path + session_id)
echo "$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try {
      const {transcript_path, session_id} = JSON.parse(d);
      if (transcript_path) {
        require('fs').writeFileSync(
          '$GIT_DIR/gitprint-active.json',
          JSON.stringify({ transcript_path, session_id, updated: new Date().toISOString() })
        );
      }
    } catch(e) {}
  });
"
