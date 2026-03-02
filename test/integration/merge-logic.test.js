const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { execSync } = require('child_process');
const path = require('path');
const { createTestRepo, readGitNote, writeGitNote, GIT_ENV } = require('../helpers/git-repo');
const { runHook } = require('../helpers/run-hook');

const FIXTURES = path.join(__dirname, '..', 'fixtures', 'transcripts');

describe('merge logic', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepo();
    dir = repo.dir;
    cleanup = repo.cleanup;
  });

  afterEach(() => cleanup());

  it('new session added to empty note', () => {
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'new-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions.length, 1);
    assert.strictEqual(note.sessions[0].session_id, 'new-1');
  });

  it('second session added alongside first', () => {
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'first' }, { cwd: dir });
    runHook('stop.sh', { transcript_path: transcript, session_id: 'second' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions.length, 2);
    const ids = note.sessions.map(s => s.session_id);
    assert.ok(ids.includes('first'));
    assert.ok(ids.includes('second'));
  });

  it('same session_id not duplicated', () => {
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'dup' }, { cwd: dir });
    runHook('stop.sh', { transcript_path: transcript, session_id: 'dup' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions.length, 1);
  });

  it('file stats accumulate across sessions', () => {
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'acc-1' }, { cwd: dir });
    runHook('stop.sh', { transcript_path: transcript, session_id: 'acc-2' }, { cwd: dir });
    const note = readGitNote(dir);
    const appFile = note.ai_files.find(f => f.file === 'src/app.js');
    assert.strictEqual(appFile.ai_lines_added, 20);
  });

  it('new files added alongside existing', () => {
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'files-1' }, { cwd: dir });
    const note1 = readGitNote(dir);
    note1.ai_files.push({ file: 'src/extra.js', ai_lines_added: 5, ai_lines_removed: 0 });
    writeGitNote(dir, note1);
    runHook('stop.sh', { transcript_path: transcript, session_id: 'files-2' }, { cwd: dir });
    const note2 = readGitNote(dir);
    const files = note2.ai_files.map(f => f.file);
    assert.ok(files.includes('src/app.js'));
    assert.ok(files.includes('src/utils.js'));
    assert.ok(files.includes('src/extra.js'));
  });

  it('corrupt existing note resets to empty', () => {
    execSync('echo "not json" | git notes --ref=gitprint add -f --file=-', {
      cwd: dir, env: { ...process.env, ...GIT_ENV }, stdio: ['pipe', 'pipe', 'pipe'],
    });
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'corrupt-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.ok(note);
    assert.strictEqual(note.sessions.length, 1);
  });

  it('session entry does not contain ai_files key', () => {
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'no-ai-files' }, { cwd: dir });
    const note = readGitNote(dir);
    const session = note.sessions[0];
    assert.ok(!session.ai_files, 'session entry should not have ai_files');
  });

  it('different tool sessions merge correctly', () => {
    const claudeTranscript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: claudeTranscript, session_id: 'multi-claude' }, { cwd: dir });
    const cursorTranscript = path.join(FIXTURES, 'cursor-session.jsonl');
    runHook('cursor-stop.sh', { transcript_path: cursorTranscript, conversation_id: 'multi-cursor' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions.length, 2);
    const tools = note.sessions.map(s => s.tool);
    assert.ok(tools.includes('claude-code'));
    assert.ok(tools.includes('cursor'));
  });

  it('existing file stats updated, not replaced', () => {
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'upd-1' }, { cwd: dir });
    runHook('stop.sh', { transcript_path: transcript, session_id: 'upd-2' }, { cwd: dir });
    const note = readGitNote(dir);
    const utilsFile = note.ai_files.find(f => f.file === 'src/utils.js');
    assert.strictEqual(utilsFile.ai_lines_added, 20); // 10 + 10
    assert.strictEqual(utilsFile.ai_lines_removed, 0);
  });
});
