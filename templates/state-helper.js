const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

function expandHome(input) {
  if (!input) return input;
  if (input === '~') return os.homedir();
  if (input.startsWith('~/')) return path.join(os.homedir(), input.slice(2));
  return input;
}

function resolveStateRoot(env = process.env) {
  if (env.GITPRINT_STATE_DIR) return path.resolve(expandHome(env.GITPRINT_STATE_DIR));

  if (process.platform === 'darwin') {
    return path.join(os.homedir(), 'Library', 'Application Support', 'gitprint', 'state');
  }

  if (process.platform === 'win32') {
    const localAppData = env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
    return path.join(localAppData, 'gitprint', 'state');
  }

  const xdgStateHome = env.XDG_STATE_HOME
    ? path.resolve(expandHome(env.XDG_STATE_HOME))
    : path.join(os.homedir(), '.local', 'state');
  return path.join(xdgStateHome, 'gitprint');
}

function buildWorktreeKey(repoRoot, gitDir) {
  return crypto
    .createHash('sha256')
    .update(`${path.resolve(repoRoot)}\n${path.resolve(gitDir)}`)
    .digest('hex')
    .slice(0, 16);
}

function resolveRepoStateContext({ cwd, gitDir, env = process.env }) {
  const repoRoot = path.resolve(cwd || process.cwd());
  const resolvedGitDir = gitDir && path.isAbsolute(gitDir)
    ? gitDir
    : path.resolve(repoRoot, gitDir || '.git');
  const stateRoot = resolveStateRoot(env);
  const worktreeKey = buildWorktreeKey(repoRoot, resolvedGitDir);
  const repoStateDir = path.join(stateRoot, worktreeKey);

  return {
    repoRoot,
    gitDir: resolvedGitDir,
    stateRoot,
    worktreeKey,
    repoStateDir,
  };
}

function resolveToolStatePaths(context, tool) {
  const toolDir = path.join(context.repoStateDir, tool);
  return {
    toolDir,
    activeFile: path.join(toolDir, 'active.json'),
    checkpointFile: path.join(toolDir, 'checkpoint.json'),
    pendingFile: path.join(toolDir, 'pending.json'),
    lockDir: path.join(toolDir, '.lock'),
  };
}

function resolveOutboxFile(context) {
  return path.join(context.repoStateDir, 'outbox.jsonl');
}

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
  return dirPath;
}

function readJson(filePath, fallback = null) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return fallback;
  }
}

function writeJsonAtomic(filePath, data) {
  ensureDir(path.dirname(filePath));
  const tempFile = path.join(
    path.dirname(filePath),
    `.${path.basename(filePath)}.${process.pid}.${Date.now()}.${Math.random().toString(16).slice(2)}.tmp`,
  );
  fs.writeFileSync(tempFile, JSON.stringify(data));
  fs.renameSync(tempFile, filePath);
}

function removePath(filePath) {
  try {
    fs.rmSync(filePath, { force: true, recursive: true });
  } catch {}
}

function isRepoStateWritable(context) {
  try {
    ensureDir(context.repoStateDir);
    const probePath = path.join(context.repoStateDir, `.probe-${process.pid}-${Date.now()}`);
    fs.writeFileSync(probePath, '');
    fs.unlinkSync(probePath);
    return true;
  } catch {
    return false;
  }
}

module.exports = {
  resolveStateRoot,
  resolveRepoStateContext,
  resolveToolStatePaths,
  resolveOutboxFile,
  ensureDir,
  readJson,
  writeJsonAtomic,
  removePath,
  isRepoStateWritable,
};
