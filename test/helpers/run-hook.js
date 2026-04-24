const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const TEMPLATES_DIR = path.join(__dirname, '..', '..', 'templates');

function runHook(hookFile, stdinJson, { cwd, env = {} } = {}) {
  const hookPath = hookFile.startsWith('/') ? hookFile : path.join(TEMPLATES_DIR, hookFile);
  const input = typeof stdinJson === 'string' ? stdinJson : JSON.stringify(stdinJson);
  const stateDir = env.GITPRINT_STATE_DIR || (cwd ? path.join(fs.realpathSync(cwd), '.gitprint-state-test') : undefined);

  if (cwd) {
    const helperDest = path.join(cwd, '.github', 'hooks', 'gitprint-state.js');
    if (!fs.existsSync(helperDest)) {
      fs.mkdirSync(path.dirname(helperDest), { recursive: true });
      fs.copyFileSync(path.join(TEMPLATES_DIR, 'state-helper.js'), helperDest);
    }
  }

  const result = spawnSync('bash', [hookPath], {
    cwd,
    input,
    env: {
      ...process.env,
      GITPRINT_DEBUG: '0',
      HOME: process.env.HOME,
      PATH: process.env.PATH,
      ...(stateDir ? { GITPRINT_STATE_DIR: stateDir } : {}),
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
