const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');

const GIT_ENV = {
  GIT_AUTHOR_NAME: 'Test',
  GIT_AUTHOR_EMAIL: 'test@test.com',
  GIT_COMMITTER_NAME: 'Test',
  GIT_COMMITTER_EMAIL: 'test@test.com',
  GIT_CONFIG_NOSYSTEM: '1',
  HOME: os.tmpdir(), // prevent ~/.gitconfig interference
};

function gitExec(cmd, dir) {
  return execSync(cmd, {
    cwd: dir,
    encoding: 'utf8',
    env: { ...process.env, ...GIT_ENV },
    stdio: ['pipe', 'pipe', 'pipe'],
  }).trim();
}

function createTestRepo() {
  const dir = path.join(os.tmpdir(), `gitprint-test-${crypto.randomUUID()}`);
  fs.mkdirSync(dir, { recursive: true });
  gitExec('git init', dir);
  gitExec('git config user.name "Test"', dir);
  gitExec('git config user.email "test@test.com"', dir);
  // Initial commit
  fs.writeFileSync(path.join(dir, 'README.md'), 'test\n');
  gitExec('git add README.md', dir);
  gitExec('git commit -m "initial commit"', dir);
  const cleanup = () => fs.rmSync(dir, { recursive: true, force: true });
  return { dir, cleanup, gitExec: (cmd) => gitExec(cmd, dir) };
}

function createTestRepoWithRemote() {
  const remoteDir = path.join(os.tmpdir(), `gitprint-remote-${crypto.randomUUID()}`);
  fs.mkdirSync(remoteDir, { recursive: true });
  gitExec('git init --bare', remoteDir);

  const dir = path.join(os.tmpdir(), `gitprint-test-${crypto.randomUUID()}`);
  fs.mkdirSync(dir, { recursive: true });
  gitExec('git init', dir);
  gitExec('git config user.name "Test"', dir);
  gitExec('git config user.email "test@test.com"', dir);
  gitExec(`git remote add origin "${remoteDir}"`, dir);
  fs.writeFileSync(path.join(dir, 'README.md'), 'test\n');
  gitExec('git add README.md', dir);
  gitExec('git commit -m "initial commit"', dir);
  gitExec('git push -u origin main 2>&1 || git push -u origin master 2>&1', dir);

  const cleanup = () => {
    fs.rmSync(dir, { recursive: true, force: true });
    fs.rmSync(remoteDir, { recursive: true, force: true });
  };
  return { dir, remoteDir, cleanup, gitExec: (cmd) => gitExec(cmd, dir) };
}

function writeGitNote(dir, data) {
  const json = typeof data === 'string' ? data : JSON.stringify(data);
  execSync('git notes --ref=gitprint add -f --file=-', {
    cwd: dir,
    input: json,
    env: { ...process.env, ...GIT_ENV },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
}

function readGitNote(dir) {
  try {
    const raw = gitExec('git notes --ref=gitprint show HEAD', dir);
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function makeCommit(dir, msg = 'test commit') {
  const filename = `file-${crypto.randomUUID().slice(0, 8)}.txt`;
  fs.writeFileSync(path.join(dir, filename), `${msg}\n`);
  gitExec(`git add ${filename}`, dir);
  gitExec(`git commit -m "${msg}"`, dir);
  return filename;
}

module.exports = { createTestRepo, createTestRepoWithRemote, writeGitNote, readGitNote, makeCommit, GIT_ENV };
