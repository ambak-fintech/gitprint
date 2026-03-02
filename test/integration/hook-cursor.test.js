const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createTestRepo, readGitNote } = require('../helpers/git-repo');
const { runHook } = require('../helpers/run-hook');

const FIXTURES = path.join(__dirname, '..', 'fixtures', 'transcripts');

describe('Cursor hook (cursor-stop.sh)', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepo();
    dir = repo.dir;
    cleanup = repo.cleanup;
  });

  afterEach(() => cleanup());

  it('maps conversation_id to session_id', () => {
    const transcript = path.join(FIXTURES, 'cursor-session.jsonl');
    runHook('cursor-stop.sh', { transcript_path: transcript, conversation_id: 'conv-abc' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions[0].session_id, 'conv-abc');
  });

  it('falls back to session_id field', () => {
    const transcript = path.join(FIXTURES, 'cursor-session.jsonl');
    runHook('cursor-stop.sh', { transcript_path: transcript, session_id: 'sess-xyz' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions[0].session_id, 'sess-xyz');
  });

  it('sets tool to cursor', () => {
    const transcript = path.join(FIXTURES, 'cursor-session.jsonl');
    runHook('cursor-stop.sh', { transcript_path: transcript, conversation_id: 'conv-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions[0].tool, 'cursor');
  });

  it('parses GPT model tokens', () => {
    const transcript = path.join(FIXTURES, 'cursor-session.jsonl');
    runHook('cursor-stop.sh', { transcript_path: transcript, conversation_id: 'conv-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions[0].input_tokens, 500);
    assert.strictEqual(note.sessions[0].output_tokens, 250);
  });

  it('tracks gpt-4o model', () => {
    const transcript = path.join(FIXTURES, 'cursor-session.jsonl');
    runHook('cursor-stop.sh', { transcript_path: transcript, conversation_id: 'conv-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.ok(note.sessions[0].models['gpt-4o']);
  });

  it('tracks file edits', () => {
    const transcript = path.join(FIXTURES, 'cursor-session.jsonl');
    runHook('cursor-stop.sh', { transcript_path: transcript, conversation_id: 'conv-1' }, { cwd: dir });
    const note = readGitNote(dir);
    const file = note.ai_files.find(f => f.file === 'src/component.tsx');
    assert.ok(file);
    assert.strictEqual(file.ai_lines_added, 2);
    assert.strictEqual(file.ai_lines_removed, 1);
  });

  it('exits 0 on empty transcript', () => {
    const transcript = path.join(FIXTURES, 'empty.jsonl');
    const result = runHook('cursor-stop.sh', { transcript_path: transcript, conversation_id: 'conv-1' }, { cwd: dir });
    assert.strictEqual(result.exitCode, 0);
  });

  it('calculates estimated_cost for gpt model', () => {
    const transcript = path.join(FIXTURES, 'cursor-session.jsonl');
    runHook('cursor-stop.sh', { transcript_path: transcript, conversation_id: 'conv-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.ok(note.sessions[0].estimated_cost >= 0);
  });
});
