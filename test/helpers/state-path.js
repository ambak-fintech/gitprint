const fs = require('fs');
const path = require('path');
const state = require('../../templates/state-helper.js');

function getStateDir(root) {
  return path.join(fs.realpathSync(root), '.gitprint-state-test');
}

function getToolPaths(root, tool) {
  const repoRoot = fs.realpathSync(root);
  const gitDir = path.join(repoRoot, '.git');
  const context = state.resolveRepoStateContext({
    cwd: repoRoot,
    gitDir,
    env: { ...process.env, GITPRINT_STATE_DIR: getStateDir(repoRoot) },
  });
  return state.resolveToolStatePaths(context, tool);
}

function getOutboxFile(root) {
  const repoRoot = fs.realpathSync(root);
  const gitDir = path.join(repoRoot, '.git');
  const context = state.resolveRepoStateContext({
    cwd: repoRoot,
    gitDir,
    env: { ...process.env, GITPRINT_STATE_DIR: getStateDir(repoRoot) },
  });
  return state.resolveOutboxFile(context);
}

module.exports = { getStateDir, getToolPaths, getOutboxFile };
