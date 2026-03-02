#!/bin/bash
# Gitprint — Setup Script
# Run once per repo clone to enable AI code attribution tracking
#
# Usage: curl -sSL https://raw.githubusercontent.com/ambak-fintech/gitprint/main/setup.sh | bash
#    or: bash setup.sh

set -e

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

GITPRINT_VERSION="${GITPRINT_VERSION:-main}"
BASE_URL="https://raw.githubusercontent.com/ambak-fintech/gitprint/${GITPRINT_VERSION}"

echo -e "${BLUE}Gitprint — Setup${NC}"
echo ""

# ─── Check we're in a git repo ───
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo -e "${RED}Not inside a git repository${NC}"
  exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

# ─── Check for node ───
if ! command -v node >/dev/null 2>&1; then
  echo -e "${RED}Node.js is required but not found${NC}"
  exit 1
fi

# ─── Download helper ───
download_hook() {
  local src="$1" dest="$2"
  curl -sSfL "${BASE_URL}/templates/${src}" -o "${dest}" || { echo -e "${RED}Download failed: ${src}${NC}"; exit 1; }
  chmod +x "${dest}"
}

# ─── Detect base branch ───
DEFAULT_BASE="main"
if git show-ref --verify --quiet refs/remotes/origin/staging 2>/dev/null; then
  DEFAULT_BASE="staging"
elif git show-ref --verify --quiet refs/remotes/origin/develop 2>/dev/null; then
  DEFAULT_BASE="develop"
fi

read -p "Base branch for PRs [$DEFAULT_BASE]: " BASE_BRANCH
BASE_BRANCH="${BASE_BRANCH:-$DEFAULT_BASE}"

# ─── Claude Code (always installed) ───
echo -e "${BLUE}Installing Claude Code hook...${NC}"
mkdir -p .claude/hooks
download_hook "stop.sh" ".claude/hooks/stop.sh"
echo -e "  ${GREEN}+${NC} .claude/hooks/stop.sh"

# Claude Code settings (merge if exists)
if [ -f .claude/settings.json ]; then
  node -e "
    const fs = require('fs');
    const existing = JSON.parse(fs.readFileSync('.claude/settings.json', 'utf8'));
    if (!existing.hooks) existing.hooks = {};
    if (!existing.hooks.Stop) existing.hooks.Stop = [];

    const hookCmd = 'bash \"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/stop.sh';
    const hasHook = existing.hooks.Stop.some(h =>
      h.hooks?.some(hh => hh.command?.includes('stop.sh'))
    );

    if (!hasHook) {
      existing.hooks.Stop.push({
        hooks: [{ type: 'command', command: hookCmd }]
      });
    }

    fs.writeFileSync('.claude/settings.json', JSON.stringify(existing, null, 2));
  " 2>/dev/null || echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/stop.sh"}]}]}}' > .claude/settings.json
else
  cat > .claude/settings.json << 'EOF'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/stop.sh"
          }
        ]
      }
    ]
  }
}
EOF
fi
echo -e "  ${GREEN}+${NC} .claude/settings.json"

# ─── Cursor support ───
CURSOR_INSTALLED=false
if [ -d .cursor ]; then
  read -p "Cursor detected. Install Cursor hook? [Y/n]: " INSTALL_CURSOR
  INSTALL_CURSOR="${INSTALL_CURSOR:-Y}"
else
  read -p "Install Cursor hook? (no .cursor/ detected) [y/N]: " INSTALL_CURSOR
  INSTALL_CURSOR="${INSTALL_CURSOR:-N}"
fi

if [[ "$INSTALL_CURSOR" =~ ^[Yy] ]]; then
  echo -e "${BLUE}Installing Cursor hook...${NC}"
  mkdir -p .cursor/hooks
  download_hook "cursor-stop.sh" ".cursor/hooks/gitprint-stop.sh"

  # Register in hooks.json
  if [ -f .cursor/hooks.json ]; then
    node -e "
      const fs = require('fs');
      const hj = JSON.parse(fs.readFileSync('.cursor/hooks.json', 'utf8'));
      if (!hj.hooks) hj.hooks = {};
      if (!hj.hooks.stop) hj.hooks.stop = [];
      const has = hj.hooks.stop.some(h => (h.command || '').includes('gitprint-stop.sh'));
      if (!has) hj.hooks.stop.push({ command: 'hooks/gitprint-stop.sh' });
      fs.writeFileSync('.cursor/hooks.json', JSON.stringify(hj, null, 2));
    " 2>/dev/null
  else
    cat > .cursor/hooks.json << 'EOF'
{
  "version": 1,
  "hooks": {
    "stop": [
      {
        "command": "hooks/gitprint-stop.sh"
      }
    ]
  }
}
EOF
  fi

  CURSOR_INSTALLED=true
  echo -e "  ${GREEN}+${NC} .cursor/hooks/gitprint-stop.sh"
  echo -e "  ${GREEN}+${NC} .cursor/hooks.json"
fi

# ─── Copilot CLI support ───
COPILOT_INSTALLED=false
COPILOT_DETECTED=false
if command -v copilot >/dev/null 2>&1 || [ -d "$HOME/.copilot" ]; then
  COPILOT_DETECTED=true
fi

if [ "$COPILOT_DETECTED" = true ]; then
  read -p "Copilot CLI detected. Install Copilot hook? [Y/n]: " INSTALL_COPILOT
  INSTALL_COPILOT="${INSTALL_COPILOT:-Y}"
else
  read -p "Install Copilot CLI hook? (not detected) [y/N]: " INSTALL_COPILOT
  INSTALL_COPILOT="${INSTALL_COPILOT:-N}"
fi

if [[ "$INSTALL_COPILOT" =~ ^[Yy] ]]; then
  echo -e "${BLUE}Installing Copilot CLI hooks...${NC}"
  mkdir -p .github/hooks
  download_hook "copilot-stop.sh" ".github/hooks/gitprint-copilot-stop.sh"
  download_hook "copilot-post-tool.sh" ".github/hooks/gitprint-copilot-post-tool.sh"

  cat > .github/hooks/gitprint-copilot.json << 'EOF'
{
  "version": 1,
  "hooks": {
    "sessionEnd": [
      {
        "type": "command",
        "bash": ".github/hooks/gitprint-copilot-stop.sh",
        "timeoutSec": 30
      }
    ],
    "postToolUse": [
      {
        "type": "command",
        "bash": ".github/hooks/gitprint-copilot-post-tool.sh",
        "timeoutSec": 10
      }
    ]
  }
}
EOF

  COPILOT_INSTALLED=true
  echo -e "  ${GREEN}+${NC} .github/hooks/gitprint-copilot-stop.sh"
  echo -e "  ${GREEN}+${NC} .github/hooks/gitprint-copilot-post-tool.sh"
  echo -e "  ${GREEN}+${NC} .github/hooks/gitprint-copilot.json"
fi

# ─── Gemini CLI support ───
GEMINI_INSTALLED=false
GEMINI_DETECTED=false
if command -v gemini >/dev/null 2>&1 || [ -d "$HOME/.gemini" ]; then
  GEMINI_DETECTED=true
fi

if [ "$GEMINI_DETECTED" = true ]; then
  read -p "Gemini CLI detected. Install Gemini hook? [Y/n]: " INSTALL_GEMINI
  INSTALL_GEMINI="${INSTALL_GEMINI:-Y}"
else
  read -p "Install Gemini CLI hook? (not detected) [y/N]: " INSTALL_GEMINI
  INSTALL_GEMINI="${INSTALL_GEMINI:-N}"
fi

if [[ "$INSTALL_GEMINI" =~ ^[Yy] ]]; then
  echo -e "${BLUE}Installing Gemini CLI hook...${NC}"
  mkdir -p .gemini/hooks
  download_hook "gemini-stop.sh" ".gemini/hooks/gitprint-stop.sh"

  # Register in settings.json
  if [ -f .gemini/settings.json ]; then
    node -e "
      const fs = require('fs');
      const existing = JSON.parse(fs.readFileSync('.gemini/settings.json', 'utf8'));
      if (!existing.hooks) existing.hooks = {};
      if (!existing.hooks.SessionEnd) existing.hooks.SessionEnd = [];
      const has = existing.hooks.SessionEnd.some(h =>
        h.hooks?.some(hh => (hh.command || '').includes('gitprint-stop.sh'))
      );
      if (!has) {
        existing.hooks.SessionEnd.push({
          hooks: [{ type: 'command', command: 'bash \"\$GEMINI_PROJECT_DIR\"/.gemini/hooks/gitprint-stop.sh' }]
        });
      }
      fs.writeFileSync('.gemini/settings.json', JSON.stringify(existing, null, 2));
    " 2>/dev/null
  else
    cat > .gemini/settings.json << 'EOF'
{
  "hooks": {
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$GEMINI_PROJECT_DIR\"/.gemini/hooks/gitprint-stop.sh"
          }
        ]
      }
    ]
  }
}
EOF
  fi

  GEMINI_INSTALLED=true
  echo -e "  ${GREEN}+${NC} .gemini/hooks/gitprint-stop.sh"
  echo -e "  ${GREEN}+${NC} .gemini/settings.json"
fi

# ─── Windsurf support ───
WINDSURF_INSTALLED=false
WINDSURF_DETECTED=false
if command -v windsurf >/dev/null 2>&1 || [ -d "$HOME/.windsurf" ]; then
  WINDSURF_DETECTED=true
fi

if [ "$WINDSURF_DETECTED" = true ]; then
  read -p "Windsurf detected. Install Windsurf hook? [Y/n]: " INSTALL_WINDSURF
  INSTALL_WINDSURF="${INSTALL_WINDSURF:-Y}"
else
  read -p "Install Windsurf hook? (not detected) [y/N]: " INSTALL_WINDSURF
  INSTALL_WINDSURF="${INSTALL_WINDSURF:-N}"
fi

if [[ "$INSTALL_WINDSURF" =~ ^[Yy] ]]; then
  echo -e "${BLUE}Installing Windsurf hook...${NC}"
  mkdir -p .windsurf/hooks
  download_hook "windsurf-stop.sh" ".windsurf/hooks/gitprint-stop.sh"

  # Register in settings.json
  if [ -f .windsurf/settings.json ]; then
    node -e "
      const fs = require('fs');
      const existing = JSON.parse(fs.readFileSync('.windsurf/settings.json', 'utf8'));
      if (!existing.hooks) existing.hooks = {};
      if (!existing.hooks.post_cascade_response_with_transcript) existing.hooks.post_cascade_response_with_transcript = [];
      const has = existing.hooks.post_cascade_response_with_transcript.some(h =>
        h.hooks?.some(hh => (hh.command || '').includes('gitprint-stop.sh'))
      );
      if (!has) {
        existing.hooks.post_cascade_response_with_transcript.push({
          hooks: [{ type: 'command', command: '.windsurf/hooks/gitprint-stop.sh' }]
        });
      }
      fs.writeFileSync('.windsurf/settings.json', JSON.stringify(existing, null, 2));
    " 2>/dev/null
  else
    cat > .windsurf/settings.json << 'EOF'
{
  "hooks": {
    "post_cascade_response_with_transcript": [
      {
        "hooks": [
          {
            "type": "command",
            "command": ".windsurf/hooks/gitprint-stop.sh"
          }
        ]
      }
    ]
  }
}
EOF
  fi

  WINDSURF_INSTALLED=true
  echo -e "  ${GREEN}+${NC} .windsurf/hooks/gitprint-stop.sh"
  echo -e "  ${GREEN}+${NC} .windsurf/settings.json"
fi

# ─── Augment Code support ───
AUGMENT_INSTALLED=false
AUGMENT_DETECTED=false
if command -v augment >/dev/null 2>&1 || [ -d "$HOME/.augment" ]; then
  AUGMENT_DETECTED=true
fi

if [ "$AUGMENT_DETECTED" = true ]; then
  read -p "Augment Code detected. Install Augment hook? [Y/n]: " INSTALL_AUGMENT
  INSTALL_AUGMENT="${INSTALL_AUGMENT:-Y}"
else
  read -p "Install Augment Code hook? (not detected) [y/N]: " INSTALL_AUGMENT
  INSTALL_AUGMENT="${INSTALL_AUGMENT:-N}"
fi

if [[ "$INSTALL_AUGMENT" =~ ^[Yy] ]]; then
  echo -e "${BLUE}Installing Augment Code hooks...${NC}"
  mkdir -p .augment/hooks
  download_hook "augment-stop.sh" ".augment/hooks/gitprint-stop.sh"
  download_hook "augment-post-tool.sh" ".augment/hooks/gitprint-post-tool.sh"

  cat > .augment/hooks/gitprint-augment.json << 'EOF'
{
  "version": 1,
  "hooks": {
    "Stop": [
      {
        "type": "command",
        "command": ".augment/hooks/gitprint-stop.sh",
        "timeoutSec": 30
      }
    ],
    "PostToolUse": [
      {
        "type": "command",
        "command": ".augment/hooks/gitprint-post-tool.sh",
        "timeoutSec": 10
      }
    ]
  }
}
EOF

  AUGMENT_INSTALLED=true
  echo -e "  ${GREEN}+${NC} .augment/hooks/gitprint-stop.sh"
  echo -e "  ${GREEN}+${NC} .augment/hooks/gitprint-post-tool.sh"
  echo -e "  ${GREEN}+${NC} .augment/hooks/gitprint-augment.json"
fi

# ─── OpenCode support ───
OPENCODE_INSTALLED=false
OPENCODE_DETECTED=false
if command -v opencode >/dev/null 2>&1 || [ -d "$HOME/.config/opencode" ]; then
  OPENCODE_DETECTED=true
fi

if [ "$OPENCODE_DETECTED" = true ]; then
  read -p "OpenCode detected. Install OpenCode plugin? [Y/n]: " INSTALL_OPENCODE
  INSTALL_OPENCODE="${INSTALL_OPENCODE:-Y}"
else
  read -p "Install OpenCode plugin? (not detected) [y/N]: " INSTALL_OPENCODE
  INSTALL_OPENCODE="${INSTALL_OPENCODE:-N}"
fi

if [[ "$INSTALL_OPENCODE" =~ ^[Yy] ]]; then
  echo -e "${BLUE}Installing OpenCode plugin...${NC}"
  mkdir -p .opencode/plugins
  curl -sSfL "${BASE_URL}/templates/opencode-plugin.js" -o ".opencode/plugins/gitprint.js" || { echo -e "${RED}Download failed: opencode-plugin.js${NC}"; exit 1; }

  OPENCODE_INSTALLED=true
  echo -e "  ${GREEN}+${NC} .opencode/plugins/gitprint.js"
fi

# ─── GitHub Action workflow ───
echo -e "${BLUE}Installing GitHub Actions workflow...${NC}"
mkdir -p .github/workflows
curl -sSfL "${BASE_URL}/templates/gitprint.yml" -o ".github/workflows/gitprint.yml" || { echo -e "${RED}Download failed: gitprint.yml${NC}"; exit 1; }

# Apply base branch substitution
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' "s/BASE_BRANCH_PLACEHOLDER/$BASE_BRANCH/g" .github/workflows/gitprint.yml
else
  sed -i "s/BASE_BRANCH_PLACEHOLDER/$BASE_BRANCH/g" .github/workflows/gitprint.yml
fi
echo -e "  ${GREEN}+${NC} .github/workflows/gitprint.yml"

# ─── Configure git to push notes automatically ───
echo -e "${BLUE}Configuring git notes push...${NC}"

if git remote get-url origin > /dev/null 2>&1; then
  EXISTING_PUSH=$(git config --get-all remote.origin.push 2>/dev/null || true)
  if ! echo "$EXISTING_PUSH" | grep -q "refs/notes/gitprint"; then
    git config --local --add remote.origin.push "+refs/notes/gitprint:refs/notes/gitprint"
  fi

  EXISTING_FETCH=$(git config --get-all remote.origin.fetch 2>/dev/null || true)
  if ! echo "$EXISTING_FETCH" | grep -q "refs/notes/gitprint"; then
    git config --local --add remote.origin.fetch "+refs/notes/gitprint:refs/notes/gitprint"
  fi
  echo -e "  ${GREEN}+${NC} git notes push/fetch config"
else
  echo -e "  ${YELLOW}!${NC} No origin remote — skipping git notes config"
  echo -e "    ${DIM}Add a remote and run:${NC}"
  echo -e "    ${DIM}git config --local --add remote.origin.push \"+refs/notes/gitprint:refs/notes/gitprint\"${NC}"
  echo -e "    ${DIM}git config --local --add remote.origin.fetch \"+refs/notes/gitprint:refs/notes/gitprint\"${NC}"
fi

# ─── Summary ───
echo ""
echo -e "${GREEN}Gitprint installed successfully!${NC}"
echo ""
echo -e "  Files created:"
echo -e "    ${BLUE}.claude/hooks/stop.sh${NC}     — Claude Code session tracker"
echo -e "    ${BLUE}.claude/settings.json${NC}     — Claude Code hook config"
echo -e "    ${BLUE}.github/workflows/gitprint.yml${NC} — GitHub Actions workflow"
[ "$CURSOR_INSTALLED" = true ] && echo -e "    ${BLUE}.cursor/hooks/gitprint-stop.sh${NC} — Cursor session tracker"
[ "$CURSOR_INSTALLED" = true ] && echo -e "    ${BLUE}.cursor/hooks.json${NC}      — Cursor hook config"
[ "$COPILOT_INSTALLED" = true ] && echo -e "    ${BLUE}.github/hooks/gitprint-copilot-stop.sh${NC} — Copilot session tracker"
[ "$COPILOT_INSTALLED" = true ] && echo -e "    ${BLUE}.github/hooks/gitprint-copilot-post-tool.sh${NC} — Copilot tool tracker"
[ "$COPILOT_INSTALLED" = true ] && echo -e "    ${BLUE}.github/hooks/gitprint-copilot.json${NC} — Copilot hook config"
[ "$GEMINI_INSTALLED" = true ] && echo -e "    ${BLUE}.gemini/hooks/gitprint-stop.sh${NC} — Gemini CLI session tracker"
[ "$GEMINI_INSTALLED" = true ] && echo -e "    ${BLUE}.gemini/settings.json${NC}   — Gemini hook config"
[ "$WINDSURF_INSTALLED" = true ] && echo -e "    ${BLUE}.windsurf/hooks/gitprint-stop.sh${NC} — Windsurf session tracker"
[ "$WINDSURF_INSTALLED" = true ] && echo -e "    ${BLUE}.windsurf/settings.json${NC} — Windsurf hook config"
[ "$AUGMENT_INSTALLED" = true ] && echo -e "    ${BLUE}.augment/hooks/gitprint-stop.sh${NC} — Augment session tracker"
[ "$AUGMENT_INSTALLED" = true ] && echo -e "    ${BLUE}.augment/hooks/gitprint-post-tool.sh${NC} — Augment tool tracker"
[ "$OPENCODE_INSTALLED" = true ] && echo -e "    ${BLUE}.opencode/plugins/gitprint.js${NC} — OpenCode plugin"
echo ""
echo -e "  Git config:"
echo -e "    ${BLUE}push refspec${NC}  — notes auto-push on \`git push\`"
echo -e "    ${BLUE}fetch refspec${NC} — notes auto-fetch on \`git pull\`"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
ADD_PATHS=".claude .github"
[ "$CURSOR_INSTALLED" = true ] && ADD_PATHS="$ADD_PATHS .cursor"
[ "$GEMINI_INSTALLED" = true ] && ADD_PATHS="$ADD_PATHS .gemini"
[ "$WINDSURF_INSTALLED" = true ] && ADD_PATHS="$ADD_PATHS .windsurf"
[ "$AUGMENT_INSTALLED" = true ] && ADD_PATHS="$ADD_PATHS .augment"
[ "$OPENCODE_INSTALLED" = true ] && ADD_PATHS="$ADD_PATHS .opencode"
echo -e "    1. Commit these files: ${BLUE}git add ${ADD_PATHS} && git commit -m 'chore: add Gitprint'${NC}"
echo -e "    2. Push to your repo: ${BLUE}git push${NC}"
echo -e "    3. Start coding with AI tools — stats appear on PRs automatically!"
echo ""
echo -e "  ${YELLOW}For teammates:${NC}"
echo -e "    Each clone needs the git config for notes. Run:"
echo -e "    ${BLUE}git config --local --add remote.origin.push \"+refs/notes/gitprint:refs/notes/gitprint\"${NC}"
echo -e "    ${BLUE}git config --local --add remote.origin.fetch \"+refs/notes/gitprint:refs/notes/gitprint\"${NC}"
echo ""
echo -e "  ${DIM}Debug hooks: GITPRINT_DEBUG=1${NC}"
echo -e "  No PAT needed — uses default GITHUB_TOKEN."
echo -e "  No cleanup jobs — Git Notes don't pollute your working tree."
echo ""
