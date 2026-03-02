const { spawnSync } = require('child_process');
const path = require('path');

const TEMPLATES_DIR = path.join(__dirname, '..', '..', 'templates');

function runHook(hookFile, stdinJson, { cwd, env = {} } = {}) {
  const hookPath = hookFile.startsWith('/') ? hookFile : path.join(TEMPLATES_DIR, hookFile);
  const input = typeof stdinJson === 'string' ? stdinJson : JSON.stringify(stdinJson);

  const result = spawnSync('bash', [hookPath], {
    cwd,
    input,
    env: {
      ...process.env,
      GITPRINT_DEBUG: '0',
      HOME: process.env.HOME,
      PATH: process.env.PATH,
      ...env,
    },
    encoding: 'utf8',
    timeout: 30000,
  });

  return {
    stdout: result.stdout || '',
    stderr: result.stderr || '',
    exitCode: result.status,
  };
}

module.exports = { runHook, TEMPLATES_DIR };
