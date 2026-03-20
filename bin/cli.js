#!/usr/bin/env node

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const readline = require('readline');
const os = require('os');
const { PRICING, matchPricing, sessionCost, fmt, fmtCost, getToolName } = require('../lib/utils');
const { checkForUpdate, runUpdate } = require('../lib/update');

const BLUE = '\x1b[34m';
const GREEN = '\x1b[32m';
const YELLOW = '\x1b[33m';
const RED = '\x1b[31m';
const DIM = '\x1b[2m';
const NC = '\x1b[0m';

const args = process.argv.slice(2);
const command = args.find(a => !a.startsWith('-'));
const YES = args.includes('--yes') || args.includes('-y') || !process.stdin.isTTY;

const HELP = `
${BLUE}Gitprint${NC} — AI code attribution for pull requests

${YELLOW}Usage:${NC}
  gitprint init [--yes]        Install hooks + workflow in current repo
  gitprint status              Show current AI stats for this branch
  gitprint report [file]       Generate markdown report (default: gitprint-report.md)
  gitprint doctor              Check if everything is configured correctly
  gitprint update              Update Gitprint to the latest version
  gitprint uninstall           Remove Gitprint from current repo

${YELLOW}Options:${NC}
  --yes, -y                    Skip all prompts, use defaults

${DIM}https://github.com/ambak-fintech/gitprint${NC}
`;

// ─── Helpers ───

function isGitRepo() {
  try {
    execSync('git rev-parse --git-dir', { stdio: 'pipe' });
    return true;
  } catch { return false; }
}

function repoRoot() {
  return execSync('git rev-parse --show-toplevel', { encoding: 'utf8' }).trim();
}

function detectBaseBranch() {
  try {
    const configured = execSync('git config gitprint.baseBranch', { encoding: 'utf8', stdio: 'pipe' }).trim();
    if (configured) return configured;
  } catch {}
  try {
    execSync('git show-ref --verify --quiet refs/remotes/origin/staging', { stdio: 'pipe' });
    return 'staging';
  } catch {}
  try {
    execSync('git show-ref --verify --quiet refs/remotes/origin/develop', { stdio: 'pipe' });
    return 'develop';
  } catch {}
  return 'main';
}

function templateDir() {
  return path.join(__dirname, '..', 'templates');
}

function hasOriginRemote() {
  try {
    execSync('git remote get-url origin', { stdio: 'pipe' });
    return true;
  } catch { return false; }
}

async function ask(question, defaultVal) {
  if (YES) return defaultVal;
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer.trim() || defaultVal);
    });
  });
}

// ─── TOOLS Registry ───
// Each tool entry defines how to install, check, and uninstall support for that AI tool.

const TOOLS = [
  {
    id: 'claude-code',
    name: 'Claude Code',
    required: true,
    detect: () => true,
    hooks: [
      { src: 'stop.sh', dest: '.claude/hooks/stop.sh' },
    ],
    config: {
      type: 'settings-json',
      path: '.claude/settings.json',
      hookKey: 'Stop',
      hookCmd: 'bash "$CLAUDE_PROJECT_DIR"/.claude/hooks/stop.sh',
      checkField: 'stop.sh',
    },
    doctorChecks: [
      { type: 'file-exec', path: '.claude/hooks/stop.sh' },
      { type: 'dry-run', path: '.claude/hooks/stop.sh', stdin: '{"transcript_path":"/dev/null","session_id":"doctor-test"}' },
      { type: 'settings-json', path: '.claude/settings.json', hookKey: 'Stop', checkField: 'stop.sh' },
    ],
    addPaths: ['.claude'],
  },
  {
    id: 'cursor',
    name: 'Cursor',
    required: false,
    detect: (root) => fs.existsSync(path.join(root, '.cursor')),
    detectHint: '.cursor/ directory',
    hooks: [
      { src: 'cursor-stop.sh', dest: '.cursor/hooks/gitprint-stop.sh' },
    ],
    config: {
      type: 'hooks-json',
      path: '.cursor/hooks.json',
      hookEvent: 'stop',
      hookEntry: { command: 'hooks/gitprint-stop.sh' },
      checkField: 'gitprint-stop.sh',
    },
    doctorChecks: [
      { type: 'file-exec', path: '.cursor/hooks/gitprint-stop.sh' },
      { type: 'hooks-json', path: '.cursor/hooks.json', hookEvent: 'stop', checkField: 'gitprint-stop.sh' },
    ],
    uninstallFiles: ['.cursor/hooks/gitprint-stop.sh'],
    uninstallConfig: {
      type: 'hooks-json',
      path: '.cursor/hooks.json',
      hookEvent: 'stop',
      matchField: 'gitprint-stop.sh',
    },
    addPaths: ['.cursor'],
  },
  {
    id: 'copilot',
    name: 'Copilot CLI',
    required: false,
    detect: () => {
      try { execSync('which copilot', { stdio: 'pipe' }); return true; } catch {}
      return fs.existsSync(path.join(os.homedir(), '.copilot'));
    },
    detectHint: '`copilot` command or ~/.copilot/',
    hooks: [
      { src: 'copilot-stop.sh', dest: '.github/hooks/gitprint-copilot-stop.sh' },
      { src: 'copilot-post-tool.sh', dest: '.github/hooks/gitprint-copilot-post-tool.sh' },
    ],
    config: {
      type: 'standalone-json',
      path: '.github/hooks/gitprint-copilot.json',
      content: {
        version: 1,
        hooks: {
          sessionEnd: [{ type: 'command', bash: '.github/hooks/gitprint-copilot-stop.sh', timeoutSec: 30 }],
          postToolUse: [{ type: 'command', bash: '.github/hooks/gitprint-copilot-post-tool.sh', timeoutSec: 10 }],
        },
      },
    },
    doctorChecks: [
      { type: 'file-exec', path: '.github/hooks/gitprint-copilot-stop.sh' },
      { type: 'file-exec', path: '.github/hooks/gitprint-copilot-post-tool.sh' },
      { type: 'standalone-json-check', path: '.github/hooks/gitprint-copilot.json', checks: ['hooks.sessionEnd', 'hooks.postToolUse'] },
    ],
    uninstallFiles: [
      '.github/hooks/gitprint-copilot-stop.sh',
      '.github/hooks/gitprint-copilot-post-tool.sh',
      '.github/hooks/gitprint-copilot.json',
    ],
    cleanupDir: '.github/hooks',
    addPaths: ['.github'],
  },
  {
    id: 'gemini',
    name: 'Gemini CLI',
    required: false,
    detect: () => {
      try { execSync('which gemini', { stdio: 'pipe' }); return true; } catch {}
      return fs.existsSync(path.join(os.homedir(), '.gemini'));
    },
    detectHint: '`gemini` command or ~/.gemini/',
    hooks: [
      { src: 'gemini-stop.sh', dest: '.gemini/hooks/gitprint-stop.sh' },
    ],
    config: {
      type: 'settings-json',
      path: '.gemini/settings.json',
      hookKey: 'SessionEnd',
      hookCmd: 'bash "$GEMINI_PROJECT_DIR"/.gemini/hooks/gitprint-stop.sh',
      checkField: 'gitprint-stop.sh',
    },
    doctorChecks: [
      { type: 'file-exec', path: '.gemini/hooks/gitprint-stop.sh' },
      { type: 'settings-json', path: '.gemini/settings.json', hookKey: 'SessionEnd', checkField: 'gitprint-stop.sh' },
    ],
    uninstallFiles: ['.gemini/hooks/gitprint-stop.sh'],
    uninstallConfig: {
      type: 'settings-json',
      path: '.gemini/settings.json',
      hookKey: 'SessionEnd',
      matchField: 'gitprint-stop.sh',
    },
    addPaths: ['.gemini'],
  },
  {
    id: 'windsurf',
    name: 'Windsurf',
    required: false,
    detect: () => {
      try { execSync('which windsurf', { stdio: 'pipe' }); return true; } catch {}
      return fs.existsSync(path.join(os.homedir(), '.windsurf'));
    },
    detectHint: '`windsurf` command or ~/.windsurf/',
    hooks: [
      { src: 'windsurf-stop.sh', dest: '.windsurf/hooks/gitprint-stop.sh' },
    ],
    config: {
      type: 'settings-json',
      path: '.windsurf/settings.json',
      hookKey: 'post_cascade_response_with_transcript',
      hookCmd: '.windsurf/hooks/gitprint-stop.sh',
      checkField: 'gitprint-stop.sh',
    },
    doctorChecks: [
      { type: 'file-exec', path: '.windsurf/hooks/gitprint-stop.sh' },
      { type: 'settings-json', path: '.windsurf/settings.json', hookKey: 'post_cascade_response_with_transcript', checkField: 'gitprint-stop.sh' },
    ],
    uninstallFiles: ['.windsurf/hooks/gitprint-stop.sh'],
    uninstallConfig: {
      type: 'settings-json',
      path: '.windsurf/settings.json',
      hookKey: 'post_cascade_response_with_transcript',
      matchField: 'gitprint-stop.sh',
    },
    addPaths: ['.windsurf'],
  },
  {
    id: 'augment',
    name: 'Augment Code',
    required: false,
    detect: () => {
      try { execSync('which augment', { stdio: 'pipe' }); return true; } catch {}
      return fs.existsSync(path.join(os.homedir(), '.augment'));
    },
    detectHint: '`augment` command or ~/.augment/',
    hooks: [
      { src: 'augment-stop.sh', dest: '.augment/hooks/gitprint-stop.sh' },
      { src: 'augment-post-tool.sh', dest: '.augment/hooks/gitprint-post-tool.sh' },
    ],
    config: {
      type: 'standalone-json',
      path: '.augment/hooks/gitprint-augment.json',
      content: {
        version: 1,
        hooks: {
          Stop: [{ type: 'command', command: '.augment/hooks/gitprint-stop.sh', timeoutSec: 30 }],
          PostToolUse: [{ type: 'command', command: '.augment/hooks/gitprint-post-tool.sh', timeoutSec: 10 }],
        },
      },
    },
    doctorChecks: [
      { type: 'file-exec', path: '.augment/hooks/gitprint-stop.sh' },
      { type: 'file-exec', path: '.augment/hooks/gitprint-post-tool.sh' },
      { type: 'standalone-json-check', path: '.augment/hooks/gitprint-augment.json', checks: ['hooks.Stop', 'hooks.PostToolUse'] },
    ],
    uninstallFiles: [
      '.augment/hooks/gitprint-stop.sh',
      '.augment/hooks/gitprint-post-tool.sh',
      '.augment/hooks/gitprint-augment.json',
    ],
    cleanupDir: '.augment/hooks',
    addPaths: ['.augment'],
  },
  {
    id: 'opencode',
    name: 'OpenCode',
    required: false,
    detect: () => {
      try { execSync('which opencode', { stdio: 'pipe' }); return true; } catch {}
      return fs.existsSync(path.join(os.homedir(), '.config', 'opencode'));
    },
    detectHint: '`opencode` command or ~/.config/opencode/',
    hooks: [
      { src: 'opencode-plugin.js', dest: '.opencode/plugins/gitprint.js', noExec: true },
    ],
    config: { type: 'none' },
    doctorChecks: [
      { type: 'file-exists', path: '.opencode/plugins/gitprint.js' },
    ],
    uninstallFiles: ['.opencode/plugins/gitprint.js'],
    cleanupDir: '.opencode/plugins',
    addPaths: ['.opencode'],
  },
];

// ─── Generic install/check/uninstall helpers ───

function installTool(root, tool) {
  for (const hook of tool.hooks) {
    const destPath = path.join(root, hook.dest);
    fs.mkdirSync(path.dirname(destPath), { recursive: true });
    const srcPath = path.join(templateDir(), hook.src);
    fs.copyFileSync(srcPath, destPath);
    if (!hook.noExec) fs.chmodSync(destPath, 0o755);
    console.log(`  ${GREEN}+${NC} ${hook.dest}`);
  }

  const cfg = tool.config;
  if (cfg.type === 'settings-json') {
    const cfgPath = path.join(root, cfg.path);
    let settings = {};
    if (fs.existsSync(cfgPath)) {
      try { settings = JSON.parse(fs.readFileSync(cfgPath, 'utf8')); } catch { settings = {}; }
    }
    if (!settings.hooks) settings.hooks = {};
    if (!settings.hooks[cfg.hookKey]) settings.hooks[cfg.hookKey] = [];

    const hasHook = settings.hooks[cfg.hookKey].some(h =>
      h.hooks?.some(hh => (hh.command || '').includes(cfg.checkField))
    );

    if (!hasHook) {
      settings.hooks[cfg.hookKey].push({
        hooks: [{ type: 'command', command: cfg.hookCmd }]
      });
    }

    fs.mkdirSync(path.dirname(cfgPath), { recursive: true });
    fs.writeFileSync(cfgPath, JSON.stringify(settings, null, 2));
    console.log(`  ${GREEN}+${NC} ${cfg.path}`);
  } else if (cfg.type === 'hooks-json') {
    const cfgPath = path.join(root, cfg.path);
    let hooksJson = { version: 1, hooks: {} };
    if (fs.existsSync(cfgPath)) {
      try { hooksJson = JSON.parse(fs.readFileSync(cfgPath, 'utf8')); } catch { hooksJson = { version: 1, hooks: {} }; }
    }
    if (!hooksJson.hooks) hooksJson.hooks = {};
    if (!hooksJson.hooks[cfg.hookEvent]) hooksJson.hooks[cfg.hookEvent] = [];

    const hasHook = hooksJson.hooks[cfg.hookEvent].some(h =>
      (h.command || '').includes(cfg.checkField)
    );
    if (!hasHook) {
      hooksJson.hooks[cfg.hookEvent].push(cfg.hookEntry);
    }

    fs.writeFileSync(cfgPath, JSON.stringify(hooksJson, null, 2));
    console.log(`  ${GREEN}+${NC} ${cfg.path}`);
  } else if (cfg.type === 'standalone-json') {
    const cfgPath = path.join(root, cfg.path);
    fs.mkdirSync(path.dirname(cfgPath), { recursive: true });
    fs.writeFileSync(cfgPath, JSON.stringify(cfg.content, null, 2));
    console.log(`  ${GREEN}+${NC} ${cfg.path}`);
  }
}

function checkTool(root, tool, isRequired) {
  const warn = isRequired ? RED : YELLOW;
  const warnChar = isRequired ? 'x' : '!';
  let ok = true;

  for (const check of (tool.doctorChecks || [])) {
    const fullPath = path.join(root, check.path);

    if (check.type === 'file-exec') {
      if (fs.existsSync(fullPath)) {
        const stat = fs.statSync(fullPath);
        const isExec = (stat.mode & 0o111) !== 0;
        if (isExec) {
          console.log(`  ${GREEN}+${NC} ${check.path} (executable)`);
        } else {
          console.log(`  ${warn}${warnChar}${NC} ${check.path} (not executable)`);
          if (isRequired) ok = false;
        }
      } else {
        console.log(`  ${warn}${warnChar}${NC} ${check.path} missing — run: gitprint init`);
        if (isRequired) ok = false;
      }
    } else if (check.type === 'file-exists') {
      if (fs.existsSync(fullPath)) {
        console.log(`  ${GREEN}+${NC} ${check.path}`);
      } else {
        console.log(`  ${warn}${warnChar}${NC} ${check.path} missing — run: gitprint init`);
        if (isRequired) ok = false;
      }
    } else if (check.type === 'dry-run') {
      try {
        execSync(
          `echo '${check.stdin}' | bash "${fullPath}"`,
          { stdio: 'pipe', timeout: 5000 }
        );
        console.log(`  ${GREEN}+${NC} hook dry-run passed`);
      } catch {
        console.log(`  ${YELLOW}!${NC} hook dry-run failed (may be normal if no git commits)`);
      }
    } else if (check.type === 'settings-json') {
      if (fs.existsSync(fullPath)) {
        try {
          const settings = JSON.parse(fs.readFileSync(fullPath, 'utf8'));
          const hasHook = settings.hooks?.[check.hookKey]?.some(h =>
            h.hooks?.some(hh => (hh.command || '').includes(check.checkField))
          );
          if (hasHook) {
            console.log(`  ${GREEN}+${NC} ${check.path} (${check.hookKey} hook registered)`);
          } else {
            console.log(`  ${warn}${warnChar}${NC} ${check.path} (${check.hookKey} hook not found — run: gitprint init)`);
            if (isRequired) ok = false;
          }
        } catch {
          console.log(`  ${warn}${warnChar}${NC} ${check.path} (invalid JSON)`);
          if (isRequired) ok = false;
        }
      } else {
        console.log(`  ${warn}${warnChar}${NC} ${check.path} missing — run: gitprint init`);
        if (isRequired) ok = false;
      }
    } else if (check.type === 'hooks-json') {
      if (fs.existsSync(fullPath)) {
        try {
          const hooksJson = JSON.parse(fs.readFileSync(fullPath, 'utf8'));
          const registered = hooksJson.hooks?.[check.hookEvent]?.some(h =>
            (h.command || '').includes(check.checkField)
          );
          if (registered) {
            console.log(`  ${GREEN}+${NC} ${check.path} (${check.checkField} registered)`);
          } else {
            console.log(`  ${warn}${warnChar}${NC} ${check.path} (${check.checkField} not registered)`);
          }
        } catch {
          console.log(`  ${warn}${warnChar}${NC} ${check.path} (invalid JSON)`);
        }
      } else {
        console.log(`  ${warn}${warnChar}${NC} ${check.path} missing — run: gitprint init`);
      }
    } else if (check.type === 'standalone-json-check') {
      if (fs.existsSync(fullPath)) {
        try {
          const config = JSON.parse(fs.readFileSync(fullPath, 'utf8'));
          const allPresent = check.checks.every(path => {
            const parts = path.split('.');
            let obj = config;
            for (const p of parts) { obj = obj?.[p]; }
            return obj && (Array.isArray(obj) ? obj.length > 0 : true);
          });
          if (allPresent) {
            console.log(`  ${GREEN}+${NC} ${check.path} (hooks registered)`);
          } else {
            console.log(`  ${warn}${warnChar}${NC} ${check.path} (missing hook registrations)`);
          }
        } catch {
          console.log(`  ${warn}${warnChar}${NC} ${check.path} (invalid JSON)`);
        }
      }
    }
  }

  return ok;
}

function uninstallTool(root, tool) {
  // Remove hook files
  for (const filePath of (tool.uninstallFiles || tool.hooks.map(h => h.dest))) {
    const fullPath = path.join(root, filePath);
    if (fs.existsSync(fullPath)) {
      fs.unlinkSync(fullPath);
      console.log(`  ${GREEN}+${NC} Removed ${filePath}`);
    }
  }

  // Clean up config
  const ucfg = tool.uninstallConfig;
  if (ucfg) {
    const cfgPath = path.join(root, ucfg.path);
    if (fs.existsSync(cfgPath)) {
      try {
        if (ucfg.type === 'settings-json') {
          const settings = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
          if (settings.hooks?.[ucfg.hookKey]) {
            settings.hooks[ucfg.hookKey] = settings.hooks[ucfg.hookKey].filter(h =>
              !h.hooks?.some(hh => (hh.command || '').includes(ucfg.matchField))
            );
            if (settings.hooks[ucfg.hookKey].length === 0) delete settings.hooks[ucfg.hookKey];
            if (Object.keys(settings.hooks).length === 0) delete settings.hooks;
          }
          if (Object.keys(settings).length === 0) {
            fs.unlinkSync(cfgPath);
            console.log(`  ${GREEN}+${NC} Removed ${ucfg.path} (was empty)`);
          } else {
            fs.writeFileSync(cfgPath, JSON.stringify(settings, null, 2));
            console.log(`  ${GREEN}+${NC} Cleaned ${ucfg.path}`);
          }
        } else if (ucfg.type === 'hooks-json') {
          const hooksJson = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
          if (hooksJson.hooks?.[ucfg.hookEvent]) {
            hooksJson.hooks[ucfg.hookEvent] = hooksJson.hooks[ucfg.hookEvent].filter(h =>
              !(h.command || '').includes(ucfg.matchField)
            );
            if (hooksJson.hooks[ucfg.hookEvent].length === 0) delete hooksJson.hooks[ucfg.hookEvent];
            if (Object.keys(hooksJson.hooks).length === 0) delete hooksJson.hooks;
          }
          if (Object.keys(hooksJson).filter(k => k !== 'version').length === 0) {
            fs.unlinkSync(cfgPath);
            console.log(`  ${GREEN}+${NC} Removed ${ucfg.path} (was empty)`);
          } else {
            fs.writeFileSync(cfgPath, JSON.stringify(hooksJson, null, 2));
            console.log(`  ${GREEN}+${NC} Cleaned ${ucfg.path}`);
          }
        }
      } catch {}
    }
  }

  // For standalone-json configs: the file itself is in uninstallFiles, already removed above.

  // Clean up directory if empty
  if (tool.cleanupDir) {
    const dirPath = path.join(root, tool.cleanupDir);
    if (fs.existsSync(dirPath)) {
      try {
        const remaining = fs.readdirSync(dirPath);
        if (remaining.length === 0) {
          fs.rmdirSync(dirPath);
          console.log(`  ${GREEN}+${NC} Removed empty ${tool.cleanupDir}/`);
        }
      } catch {}
    }
  }
}

// ─── Data gathering ───

function gatherBranchData(base) {
  try {
    execSync('git fetch origin refs/notes/gitprint:refs/notes/gitprint 2>/dev/null', { stdio: 'pipe' });
  } catch {}

  let commits;
  try {
    commits = execSync(`git log origin/${base}..HEAD --format="%H"`, { encoding: 'utf8' })
      .trim().split('\n').filter(Boolean);
  } catch {
    return null;
  }

  if (commits.length === 0) return null;

  let totalSessions = 0, totalTokens = 0, totalTurns = 0, totalCost = 0, notesFound = 0;
  const files = {};
  const tools = {};
  const sessions = [];

  for (const sha of commits) {
    try {
      const note = execSync(`git notes --ref=gitprint show ${sha} 2>/dev/null`, { encoding: 'utf8' }).trim();
      if (!note) continue;
      notesFound++;

      const data = JSON.parse(note);

      for (const s of (data.sessions || [])) {
        totalSessions++;
        totalTokens += (s.input_tokens || 0) + (s.output_tokens || 0) +
                       (s.cache_creation_tokens || 0) + (s.cache_read_tokens || 0);
        totalTurns += s.turns || 0;
        const tool = s.tool || 'claude-code';
        tools[tool] = (tools[tool] || 0) + 1;
        totalCost += sessionCost(s);
        sessions.push(s);
      }

      for (const f of (data.ai_files || [])) {
        if (!files[f.file]) files[f.file] = { added: 0, removed: 0 };
        files[f.file].added += f.ai_lines_added || 0;
        files[f.file].removed += f.ai_lines_removed || 0;
      }
    } catch {}
  }

  return {
    commits, notesFound, totalSessions, totalTokens, totalTurns, totalCost,
    files, tools, sessions,
  };
}

// ─── INIT ───

async function init() {
  if (!isGitRepo()) {
    console.log(`${RED}Not inside a git repository${NC}`);
    process.exit(1);
  }

  const root = repoRoot();
  const detected = detectBaseBranch();

  console.log(`${BLUE}Gitprint — Init${NC}`);
  console.log('');

  const base = await ask(`  Base branch for PRs [${detected}]: `, detected);
  execSync(`git config gitprint.baseBranch ${base}`, { stdio: 'pipe' });
  console.log(`   Base branch: ${GREEN}${base}${NC}`);
  console.log('');

  // Workflow
  const workflowDir = path.join(root, '.github', 'workflows');
  fs.mkdirSync(workflowDir, { recursive: true });

  const workflowDest = path.join(workflowDir, 'gitprint.yml');
  if (fs.existsSync(workflowDest)) {
    const overwrite = await ask(`  ${YELLOW}gitprint.yml already exists. Overwrite? [Y/n]:${NC} `, 'Y');
    if (overwrite.toLowerCase() === 'n') {
      console.log(`  ${DIM}skipped${NC} .github/workflows/gitprint.yml`);
    } else {
      const workflowSrc = path.join(templateDir(), 'gitprint.yml');
      let workflow = fs.readFileSync(workflowSrc, 'utf8');
      workflow = workflow.replace(/BASE_BRANCH_PLACEHOLDER/g, base);
      fs.writeFileSync(workflowDest, workflow);
      console.log(`  ${GREEN}+${NC} .github/workflows/gitprint.yml`);
    }
  } else {
    const workflowSrc = path.join(templateDir(), 'gitprint.yml');
    let workflow = fs.readFileSync(workflowSrc, 'utf8');
    workflow = workflow.replace(/BASE_BRANCH_PLACEHOLDER/g, base);
    fs.writeFileSync(workflowDest, workflow);
    console.log(`  ${GREEN}+${NC} .github/workflows/gitprint.yml`);
  }

  // Install tools via registry
  const installed = [];
  for (const tool of TOOLS) {
    if (tool.required) {
      installTool(root, tool);
      installed.push(tool);
      continue;
    }

    const isDetected = tool.detect(root);
    let shouldInstall = false;

    if (isDetected) {
      const answer = await ask(`  ${tool.name} detected. Install ${tool.name} hook? [Y/n]: `, 'Y');
      shouldInstall = answer.toLowerCase() !== 'n';
    } else {
      const answer = await ask(`  Install ${tool.name} hook? (not detected) [y/N]: `, 'N');
      shouldInstall = answer.toLowerCase() === 'y';
    }

    if (shouldInstall) {
      installTool(root, tool);
      installed.push(tool);
    }
  }

  // Origin remote + refspec
  if (hasOriginRemote()) {
    const pushRefs = execSync('git config --get-all remote.origin.push 2>/dev/null || true', { encoding: 'utf8' });
    if (!pushRefs.includes('refs/notes/gitprint')) {
      execSync('git config --local --add remote.origin.push "+refs/notes/gitprint:refs/notes/gitprint"');
    }

    const fetchRefs = execSync('git config --get-all remote.origin.fetch 2>/dev/null || true', { encoding: 'utf8' });
    if (!fetchRefs.includes('refs/notes/gitprint')) {
      execSync('git config --local --add remote.origin.fetch "+refs/notes/gitprint:refs/notes/gitprint"');
    }
    console.log(`  ${GREEN}+${NC} git notes push/fetch config`);
  } else {
    console.log(`  ${YELLOW}!${NC} no origin remote — skipping git notes config`);
    console.log(`    ${DIM}Add a remote and run:${NC}`);
    console.log(`    ${DIM}git config --local --add remote.origin.push "+refs/notes/gitprint:refs/notes/gitprint"${NC}`);
    console.log(`    ${DIM}git config --local --add remote.origin.fetch "+refs/notes/gitprint:refs/notes/gitprint"${NC}`);
  }

  console.log('');
  console.log(`${GREEN}Gitprint installed!${NC}`);
  console.log('');

  const addPathSet = new Set(['.github']);
  for (const tool of installed) {
    for (const p of (tool.addPaths || [])) addPathSet.add(p);
  }
  const addPaths = [...addPathSet].sort().join(' ');

  console.log(`  ${YELLOW}Next:${NC}`);
  console.log(`  ${BLUE}git add ${addPaths} && git commit -m "chore: add gitprint"${NC}`);
  console.log(`  ${BLUE}git push${NC}`);
  console.log('');
}

// ─── STATUS ───

function status() {
  if (!isGitRepo()) {
    console.log(`${RED}Not inside a git repository${NC}`);
    process.exit(1);
  }

  const base = detectBaseBranch();
  let branch;
  try {
    branch = execSync('git rev-parse --abbrev-ref HEAD', { encoding: 'utf8' }).trim();
  } catch {
    console.log(`${RED}Cannot determine current branch${NC}`);
    process.exit(1);
  }

  console.log(`${BLUE}Gitprint — Status${NC}`);
  console.log(`   Branch: ${GREEN}${branch}${NC} → ${base}`);
  console.log('');

  const data = gatherBranchData(base);
  if (!data) {
    console.log(`  ${DIM}No commits ahead of ${base}${NC}`);
    return;
  }

  const { commits, notesFound, totalSessions, totalTokens, totalTurns, totalCost, files, tools } = data;

  const toolSummary = Object.entries(tools).map(([t, n]) => `${getToolName(t)} (${n})`).join(', ');
  console.log(`  Commits: ${commits.length}  |  Notes: ${notesFound}  |  Sessions: ${totalSessions}`);
  console.log(`  Tokens:  ${fmt(totalTokens)}  |  Turns: ${totalTurns}  |  Cost: ${fmtCost(totalCost)}`);
  if (toolSummary) console.log(`  Tools:   ${toolSummary}`);
  console.log('');

  const fileEntries = Object.entries(files);
  if (fileEntries.length > 0) {
    console.log(`  ${YELLOW}AI-touched files:${NC}`);
    for (const [file, stat] of fileEntries.sort((a, b) => b[1].added - a[1].added)) {
      console.log(`    ${GREEN}+${stat.added}${NC} ${RED}-${stat.removed}${NC}  ${file}`);
    }
  } else {
    console.log(`  ${DIM}No AI-edited files tracked yet${NC}`);
  }

  console.log('');
}

// ─── REPORT ───

async function report() {
  if (!isGitRepo()) {
    console.log(`${RED}Not inside a git repository${NC}`);
    process.exit(1);
  }

  const base = detectBaseBranch();
  let branch;
  try {
    branch = execSync('git rev-parse --abbrev-ref HEAD', { encoding: 'utf8' }).trim();
  } catch {
    console.log(`${RED}Cannot determine current branch${NC}`);
    process.exit(1);
  }

  const outFile = args.find(a => a !== 'report' && !a.startsWith('-')) || 'gitprint-report.md';

  console.log(`${BLUE}Gitprint — Report${NC}`);
  console.log(`   Branch: ${GREEN}${branch}${NC} → ${base}`);
  console.log('');

  const data = gatherBranchData(base);
  if (!data) {
    console.log(`  ${DIM}No commits ahead of ${base}${NC}`);
    return;
  }

  const { commits, notesFound, totalSessions, totalTokens, totalTurns, totalCost, files, tools, sessions } = data;

  // Model aggregation
  const modelAgg = {};
  for (const s of sessions) {
    for (const [model, info] of Object.entries(s.models || {})) {
      if (!modelAgg[model]) modelAgg[model] = { input_tokens: 0, output_tokens: 0, turns: 0 };
      modelAgg[model].input_tokens += info.input_tokens || 0;
      modelAgg[model].output_tokens += info.output_tokens || 0;
      modelAgg[model].turns += info.turns || 0;
    }
  }

  const getShortName = (m) => {
    const ml = m.toLowerCase();
    if (ml.includes('opus')) return 'Opus';
    if (ml.includes('sonnet')) return 'Sonnet';
    if (ml.includes('haiku')) return 'Haiku';
    return m.split('/').pop().split('-').slice(0, 3).join('-');
  };

  // Build markdown
  const lines = [
    `# Gitprint — AI Attribution Report`,
    '',
    `**Branch:** \`${branch}\` → \`${base}\``,
    `**Generated:** ${new Date().toISOString().slice(0, 16)}`,
    `**Commits:** ${commits.length} | **Notes:** ${notesFound} | **Sessions:** ${totalSessions}`,
    '',
    '## Summary',
    '',
    '| Metric | Value |',
    '|--------|-------|',
    `| Total tokens | ${fmt(totalTokens)} |`,
    `| Total turns | ${totalTurns} |`,
    `| Estimated cost | ${fmtCost(totalCost)} |`,
    `| Sessions | ${totalSessions} |`,
    `| Tools | ${Object.entries(tools).map(([t, n]) => `${getToolName(t)} (${n})`).join(', ') || 'None'} |`,
    '',
  ];

  // Models table
  const modelEntries = Object.entries(modelAgg);
  if (modelEntries.length > 0) {
    lines.push('## Models Used', '');
    lines.push('| Model | Input Tokens | Output Tokens | Total | Turns |');
    lines.push('|-------|-------------|--------------|-------|-------|');
    for (const [model, info] of modelEntries.sort((a, b) => (b.input_tokens + b.output_tokens) - (a.input_tokens + a.output_tokens))) {
      const total = info.input_tokens + info.output_tokens;
      lines.push(`| ${getShortName(model)} | ${fmt(info.input_tokens)} | ${fmt(info.output_tokens)} | ${fmt(total)} | ${info.turns} |`);
    }
    lines.push('');
  }

  // Sessions table
  if (sessions.length > 0) {
    lines.push('## Session Breakdown', '');
    lines.push('| # | Tool | Timestamp | Input | Output | Cost | Turns | Models |');
    lines.push('|---|------|-----------|-------|--------|------|-------|--------|');
    const sorted = sessions.sort((a, b) => (a.timestamp || '').localeCompare(b.timestamp || ''));
    sorted.forEach((s, i) => {
      const sessionModels = Object.keys(s.models || {}).map(m => getShortName(m)).join(', ');
      const ts = (s.timestamp || '').slice(0, 16);
      const tool = getToolName(s.tool || 'claude-code');
      const cost = fmtCost(sessionCost(s));
      lines.push(`| ${i + 1} | ${tool} | ${ts} | ${fmt(s.input_tokens || 0)} | ${fmt(s.output_tokens || 0)} | ${cost} | ${s.turns || 0} | ${sessionModels} |`);
    });
    lines.push('');
  }

  // Files table
  const fileEntries = Object.entries(files);
  if (fileEntries.length > 0) {
    lines.push('## AI-Touched Files', '');
    lines.push('| File | AI Lines Added | AI Lines Removed |');
    lines.push('|------|---------------|-----------------|');
    for (const [file, stat] of fileEntries.sort((a, b) => b[1].added - a[1].added)) {
      lines.push(`| \`${file}\` | +${stat.added} | -${stat.removed} |`);
    }
    lines.push('');
  }

  lines.push('---', '_Generated by [Gitprint](https://github.com/ambak-fintech/gitprint)_', '');

  const content = lines.join('\n');
  fs.writeFileSync(outFile, content);
  console.log(`  ${GREEN}+${NC} Report written to ${BLUE}${outFile}${NC}`);
  console.log('');
}

// ─── DOCTOR ───

function doctor() {
  if (!isGitRepo()) {
    console.log(`${RED}Not inside a git repository${NC}`);
    process.exit(1);
  }

  const root = repoRoot();
  console.log(`${BLUE}Gitprint — Doctor${NC}`);
  console.log('');

  let ok = true;

  // Check each tool
  for (const tool of TOOLS) {
    if (tool.required) {
      console.log(`  ${DIM}${tool.name}${NC}`);
      if (!checkTool(root, tool, true)) ok = false;
    } else {
      // Only show optional tools if they have files installed
      const hasAnyFile = tool.hooks.some(h => fs.existsSync(path.join(root, h.dest)));
      const hasConfig = tool.config.path && fs.existsSync(path.join(root, tool.config.path));
      if (hasAnyFile || hasConfig) {
        console.log('');
        console.log(`  ${DIM}${tool.name}${NC}`);
        checkTool(root, tool, false);
      }
    }
  }

  // Workflow check
  const workflowPath = path.join(root, '.github', 'workflows', 'gitprint.yml');
  if (fs.existsSync(workflowPath)) {
    console.log(`  ${GREEN}+${NC} .github/workflows/gitprint.yml`);
  } else {
    console.log(`  ${RED}x${NC} .github/workflows/gitprint.yml missing — run: gitprint init`);
    ok = false;
  }

  // Git config checks
  console.log('');
  console.log(`  ${DIM}Git config${NC}`);

  if (hasOriginRemote()) {
    const pushRefs = execSync('git config --get-all remote.origin.push 2>/dev/null || true', { encoding: 'utf8' });
    if (pushRefs.includes('refs/notes/gitprint')) {
      console.log(`  ${GREEN}+${NC} git push refspec for notes`);
    } else {
      console.log(`  ${RED}x${NC} git push refspec missing — run: gitprint init`);
      ok = false;
    }

    const fetchRefs = execSync('git config --get-all remote.origin.fetch 2>/dev/null || true', { encoding: 'utf8' });
    if (fetchRefs.includes('refs/notes/gitprint')) {
      console.log(`  ${GREEN}+${NC} git fetch refspec for notes`);
    } else {
      console.log(`  ${RED}x${NC} git fetch refspec missing — run: gitprint init`);
      ok = false;
    }
  } else {
    console.log(`  ${YELLOW}!${NC} no origin remote — refspec checks skipped`);
    console.log(`    ${DIM}Add a remote, then run: gitprint init${NC}`);
  }

  // Node.js check
  try {
    const nodeVersion = execSync('node --version', { encoding: 'utf8' }).trim();
    console.log(`  ${GREEN}+${NC} Node.js ${nodeVersion}`);
  } catch {
    console.log(`  ${RED}x${NC} Node.js not found (required for transcript parsing)`);
    ok = false;
  }

  console.log('');
  if (ok) {
    console.log(`  ${GREEN}All checks passed!${NC}`);
  } else {
    console.log(`  ${YELLOW}Some issues found. Run: gitprint init${NC}`);
  }
  console.log('');
}

// ─── UNINSTALL ───

function uninstall() {
  if (!isGitRepo()) {
    console.log(`${RED}Not inside a git repository${NC}`);
    process.exit(1);
  }

  const root = repoRoot();
  console.log(`${BLUE}Gitprint — Uninstall${NC}`);
  console.log('');

  for (const tool of TOOLS) {
    uninstallTool(root, tool);
  }

  // Remove workflow
  const workflowPath = path.join(root, '.github', 'workflows', 'gitprint.yml');
  if (fs.existsSync(workflowPath)) {
    fs.unlinkSync(workflowPath);
    console.log(`  ${GREEN}+${NC} Removed .github/workflows/gitprint.yml`);
  }

  // Remove git config
  try { execSync('git config --unset gitprint.baseBranch', { stdio: 'pipe' }); } catch {}

  // Clean up .github/hooks/ if empty
  const ghHooksDir = path.join(root, '.github', 'hooks');
  if (fs.existsSync(ghHooksDir)) {
    try {
      const remaining = fs.readdirSync(ghHooksDir);
      if (remaining.length === 0) {
        fs.rmdirSync(ghHooksDir);
        console.log(`  ${GREEN}+${NC} Removed empty .github/hooks/`);
      }
    } catch {}
  }

  console.log('');
  console.log(`  ${DIM}Git notes config preserved. To remove manually:${NC}`);
  console.log(`  ${DIM}git config --local --unset-all remote.origin.push "+refs/notes/gitprint:refs/notes/gitprint"${NC}`);
  console.log(`  ${DIM}git config --local --unset-all remote.origin.fetch "+refs/notes/gitprint:refs/notes/gitprint"${NC}`);
  console.log('');
  console.log(`  ${GREEN}Gitprint uninstalled.${NC} Commit the changes to remove from repo.`);
  console.log('');
}

// ─── Route ───

async function main() {
  // Fire-and-forget update check — runs in parallel with command
  const updateNotice = (command !== 'update') ? checkForUpdate().then(result => {
    if (result?.updateAvailable) {
      console.log(`\n  Update available: ${result.current} → ${result.latest}`);
      console.log(`  Run ${BLUE}gitprint update${NC} to upgrade.`);
    }
  }).catch(() => {}) : Promise.resolve();

  switch (command) {
    case 'init':
      await init();
      break;
    case 'status':
      status();
      break;
    case 'report':
      await report();
      break;
    case 'doctor':
      doctor();
      break;
    case 'update':
      await runUpdate();
      break;
    case 'uninstall':
      uninstall();
      break;
    case '--help':
    case '-h':
    case undefined:
      console.log(HELP);
      break;
    default:
      console.log(`${RED}Unknown command: ${command}${NC}`);
      console.log(HELP);
      process.exit(1);
  }

  await updateNotice;
}

main().catch(err => {
  console.error(`${RED}${err.message}${NC}`);
  process.exit(1);
});
