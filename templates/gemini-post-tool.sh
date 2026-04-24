#!/bin/bash
# Gitprint — AfterTool Hook (Gemini CLI)
# Fires after every Gemini tool call. Writes active session marker
# so the post-commit hook knows where to find the current transcript.

INPUT=$(cat)

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0

echo "$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try {
      const { transcript_path, session_id, cwd } = JSON.parse(d);
      if (transcript_path) {
        require('fs').writeFileSync(
          '$GIT_DIR/gitprint-gemini-active.json',
          JSON.stringify({ transcript_path, session_id, cwd, updated: new Date().toISOString() })
        );
      }
    } catch(e) {}
  });
"

exit 0
