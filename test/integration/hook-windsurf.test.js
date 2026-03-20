const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const { createTestRepo, readGitNote } = require('../helpers/git-repo');
const { runHook } = require('../helpers/run-hook');

const FIXTURES = path.join(__dirname, '..', 'fixtures', 'transcripts');

describe('Windsurf hook (windsurf-stop.sh)', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepo();
    dir = repo.dir;
    cleanup = repo.cleanup;
  });

  afterEach(() => cleanup());

  it('uses trajectory_id as session_id', () => {
    const transcript = path.join(FIXTURES, 'windsurf-session.jsonl');
    runHook('windsurf-stop.sh', { transcript_path: transcript, trajectory_id: 'traj-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions[0].session_id, 'traj-1');
  });

  it('falls back to execution_id', () => {
    const transcript = path.join(FIXTURES, 'windsurf-session.jsonl');
    runHook('windsurf-stop.sh', { transcript_path: transcript, execution_id: 'exec-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions[0].session_id, 'exec-1');
  });

  it('sets all tokens to 0', () => {
    const transcript = path.join(FIXTURES, 'windsurf-session.jsonl');
    runHook('windsurf-stop.sh', { transcript_path: transcript, trajectory_id: 'traj-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions[0].input_tokens, 0);
    assert.strictEqual(note.sessions[0].output_tokens, 0);
    assert.strictEqual(note.sessions[0].cache_creation_tokens, 0);
    assert.strictEqual(note.sessions[0].cache_read_tokens, 0);
  });

  it('sets estimated_cost to 0', () => {
    const transcript = path.join(FIXTURES, 'windsurf-session.jsonl');
    runHook('windsurf-stop.sh', { transcript_path: transcript, trajectory_id: 'traj-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions[0].estimated_cost, 0);
  });

  it('counts turns from human entries and api_calls from assistant entries', () => {
    const transcript = path.join(FIXTURES, 'windsurf-session.jsonl');
    runHook('windsurf-stop.sh', { transcript_path: transcript, trajectory_id: 'traj-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions[0].turns, 1);
    assert.strictEqual(note.sessions[0].api_calls, 1);
  });

  it('tracks file edits', () => {
    const transcript = path.join(FIXTURES, 'windsurf-session.jsonl');
    runHook('windsurf-stop.sh', { transcript_path: transcript, trajectory_id: 'traj-1' }, { cwd: dir });
    const note = readGitNote(dir);
    const file = note.ai_files.find(f => f.file === 'src/index.ts');
    assert.ok(file);
    assert.strictEqual(file.ai_lines_added, 2);
    assert.strictEqual(file.ai_lines_removed, 1);
  });

  it('sets tool to windsurf', () => {
    const transcript = path.join(FIXTURES, 'windsurf-session.jsonl');
    runHook('windsurf-stop.sh', { transcript_path: transcript, trajectory_id: 'traj-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions[0].tool, 'windsurf');
  });
});
