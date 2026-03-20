const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createTestRepo, readGitNote } = require('../helpers/git-repo');
const { runHook } = require('../helpers/run-hook');

const FIXTURES = path.join(__dirname, '..', 'fixtures', 'transcripts');

describe('Gemini CLI hook (gemini-stop.sh)', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepo();
    dir = repo.dir;
    cleanup = repo.cleanup;
  });

  afterEach(() => cleanup());

  it('parses message_update entries with tokens object', () => {
    const transcript = path.join(FIXTURES, 'gemini-session.jsonl');
    runHook('gemini-stop.sh', { transcript_path: transcript, session_id: 'gem-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.ok(note.sessions[0].input_tokens >= 300);
  });

  it('parses top-level usage entries', () => {
    const transcript = path.join(FIXTURES, 'gemini-session.jsonl');
    runHook('gemini-stop.sh', { transcript_path: transcript, session_id: 'gem-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions[0].input_tokens, 500);
    assert.strictEqual(note.sessions[0].output_tokens, 250);
  });

  it('counts turns correctly', () => {
    const transcript = path.join(FIXTURES, 'gemini-session.jsonl');
    runHook('gemini-stop.sh', { transcript_path: transcript, session_id: 'gem-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions[0].turns, 2);
    assert.strictEqual(note.sessions[0].api_calls, 2);
  });

  it('handles replace tool name', () => {
    const transcript = path.join(FIXTURES, 'gemini-session.jsonl');
    runHook('gemini-stop.sh', { transcript_path: transcript, session_id: 'gem-1' }, { cwd: dir });
    const note = readGitNote(dir);
    const mainPy = note.ai_files.find(f => f.file === 'src/main.py');
    assert.ok(mainPy);
    assert.strictEqual(mainPy.ai_lines_added, 2);
    assert.strictEqual(mainPy.ai_lines_removed, 1);
  });

  it('handles write_file tool name via tool_call entry', () => {
    const transcript = path.join(FIXTURES, 'gemini-session.jsonl');
    runHook('gemini-stop.sh', { transcript_path: transcript, session_id: 'gem-1' }, { cwd: dir });
    const note = readGitNote(dir);
    const configPy = note.ai_files.find(f => f.file === 'src/config.py');
    assert.ok(configPy);
    assert.strictEqual(configPy.ai_lines_added, 3);
    assert.strictEqual(configPy.ai_lines_removed, 0);
  });

  it('sets tool to gemini', () => {
    const transcript = path.join(FIXTURES, 'gemini-session.jsonl');
    runHook('gemini-stop.sh', { transcript_path: transcript, session_id: 'gem-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.strictEqual(note.sessions[0].tool, 'gemini');
  });

  it('tracks gemini-2.5-pro model', () => {
    const transcript = path.join(FIXTURES, 'gemini-session.jsonl');
    runHook('gemini-stop.sh', { transcript_path: transcript, session_id: 'gem-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.ok(note.sessions[0].models['gemini-2.5-pro']);
  });

  it('calculates estimated_cost', () => {
    const transcript = path.join(FIXTURES, 'gemini-session.jsonl');
    runHook('gemini-stop.sh', { transcript_path: transcript, session_id: 'gem-1' }, { cwd: dir });
    const note = readGitNote(dir);
    assert.ok(note.sessions[0].estimated_cost >= 0);
  });
});
