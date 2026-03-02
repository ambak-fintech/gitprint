const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createTestRepo, readGitNote, writeGitNote } = require('../helpers/git-repo');
const { runHook } = require('../helpers/run-hook');

const FIXTURES = path.join(__dirname, '..', 'fixtures', 'transcripts');

describe('Claude Code hook (stop.sh)', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepo();
    dir = repo.dir;
    cleanup = repo.cleanup;
  });

  afterEach(() => cleanup());

  it('parses tokens from assistant entries', () => {
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'test-123' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.ok(note);
    const session = note.sessions[0];
    assert.strictEqual(session.input_tokens, 1000);
    assert.strictEqual(session.output_tokens, 500);
    assert.strictEqual(session.cache_creation_tokens, 200);
    assert.strictEqual(session.cache_read_tokens, 100);
  });

  it('counts turns correctly', () => {
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'test-123' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions[0].turns, 2);
  });

  it('tracks model names and per-model tokens', () => {
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'test-123' }, { cwd: dir });
    const note = readGitNote(dir);
    const models = note.sessions[0].models;
    assert.ok(models['claude-sonnet-4-6']);
    assert.strictEqual(models['claude-sonnet-4-6'].turns, 2);
  });

  it('extracts Edit tool_use line counts', () => {
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'test-123' }, { cwd: dir });
    const note = readGitNote(dir);
    const appFile = note.ai_files.find(f => f.file === 'src/app.js');
    assert.ok(appFile);
    // Edit: 5 added, 3 removed + MultiEdit: (3+2)=5 added, (2+1)=3 removed = total 10 added, 6 removed
    assert.strictEqual(appFile.ai_lines_added, 10);
    assert.strictEqual(appFile.ai_lines_removed, 6);
  });

  it('extracts Write tool_use (full content as lines added)', () => {
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'test-123' }, { cwd: dir });
    const note = readGitNote(dir);
    const utilsFile = note.ai_files.find(f => f.file === 'src/utils.js');
    assert.ok(utilsFile);
    assert.strictEqual(utilsFile.ai_lines_added, 10);
    assert.strictEqual(utilsFile.ai_lines_removed, 0);
  });

  it('sets tool to claude-code', () => {
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'test-123' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions[0].tool, 'claude-code');
  });

  it('calculates estimated_cost', () => {
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'test-123' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.ok(note.sessions[0].estimated_cost >= 0);
    assert.ok(typeof note.sessions[0].estimated_cost === 'number');
  });

  it('skips isSidechain entries', () => {
    const transcript = path.join(FIXTURES, 'sidechain.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'test-side' }, { cwd: dir });
    const note = readGitNote(dir);
    // Only the non-sidechain, non-error entry should be counted
    assert.strictEqual(note.sessions[0].input_tokens, 100);
    assert.strictEqual(note.sessions[0].output_tokens, 50);
    // should-skip.js from sidechain entry should NOT appear
    const skipFile = note.ai_files.find(f => f.file === 'should-skip.js');
    assert.ok(!skipFile, 'sidechain file edits should be skipped');
  });

  it('merges with existing note on HEAD', () => {
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    // First session
    runHook('stop.sh', { transcript_path: transcript, session_id: 'session-1' }, { cwd: dir });
    // Second session
    runHook('stop.sh', { transcript_path: transcript, session_id: 'session-2' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions.length, 2);
    // File stats should accumulate
    const appFile = note.ai_files.find(f => f.file === 'src/app.js');
    assert.strictEqual(appFile.ai_lines_added, 20); // 10 + 10
  });

  it('deduplicates same session_id', () => {
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'same-id' }, { cwd: dir });
    runHook('stop.sh', { transcript_path: transcript, session_id: 'same-id' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions.length, 1);
  });

  it('exits 0 on missing transcript', () => {
    const result = runHook('stop.sh', { transcript_path: '/nonexistent/path.jsonl', session_id: 'test' }, { cwd: dir });
    assert.strictEqual(result.exitCode, 0);
  });

  it('exits 0 with empty stdin', () => {
    const result = runHook('stop.sh', {}, { cwd: dir });
    assert.strictEqual(result.exitCode, 0);
  });

  it('writes valid JSON note', () => {
    const transcript = path.join(FIXTURES, 'claude-session.jsonl');
    runHook('stop.sh', { transcript_path: transcript, session_id: 'test-json' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.ok(note.sessions);
    assert.ok(note.ai_files);
    assert.ok(Array.isArray(note.sessions));
    assert.ok(Array.isArray(note.ai_files));
  });

  it('handles malformed transcript gracefully', () => {
    const transcript = path.join(FIXTURES, 'malformed.jsonl');
    const result = runHook('stop.sh', { transcript_path: transcript, session_id: 'test-malformed' }, { cwd: dir });
    assert.strictEqual(result.exitCode, 0);
    const note = readGitNote(dir);
    assert.ok(note);
    // Should parse the valid lines (input: 100+200=300, output: 50+100=150)
    assert.strictEqual(note.sessions[0].input_tokens, 300);
  });
});
