#!/bin/bash
# Gitprint — OpenAI Codex Stop Hook
# Fires when a Codex conversation turn ends.
# Refreshes an active transcript marker so post-commit can attach
# Codex transcript deltas to the next git commit.

log() { [ "${GITPRINT_DEBUG:-0}" = "1" ] && echo "[gitprint:codex] $*" >&2; }

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | node -e "
  let d=''; process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{ try { console.log(JSON.parse(d).session_id||''); } catch { console.log(''); } });
")
TRANSCRIPT_PATH=$(echo "$INPUT" | node -e "
  let d=''; process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{ try { console.log(JSON.parse(d).transcript_path||''); } catch { console.log(''); } });
")
MODEL=$(echo "$INPUT" | node -e "
  let d=''; process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{ try { console.log(JSON.parse(d).model||''); } catch { console.log(''); } });
")
CWD=$(echo "$INPUT" | node -e "
  let d=''; process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{ try { console.log(JSON.parse(d).cwd||''); } catch { console.log(''); } });
")

[ -n "$SESSION_ID" ] || { log "no session_id — skipping"; exit 0; }
[ -f "$TRANSCRIPT_PATH" ] || { log "transcript not found: $TRANSCRIPT_PATH"; exit 0; }

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || { log "not a git repo"; exit 0; }

node - "$GIT_DIR/gitprint-codex-active.json" "$TRANSCRIPT_PATH" "$SESSION_ID" "$MODEL" "$CWD" <<'NODEEOF'
const fs = require('fs');
const [filePath, transcriptPath, sessionId, model, cwd] = process.argv.slice(2);

try {
  fs.writeFileSync(filePath, JSON.stringify({
    transcript_path: transcriptPath,
    session_id: sessionId,
    model: model || '',
    cwd: cwd || process.cwd(),
    updated: new Date().toISOString(),
  }));
} catch {}
NODEEOF

log "updated active transcript marker"
printf '{}'
exit 0
