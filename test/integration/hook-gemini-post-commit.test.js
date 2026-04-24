const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createTestRepo, readGitNote, makeCommit } = require('../helpers/git-repo');
const { runHook } = require('../helpers/run-hook');
const { getToolPaths } = require('../helpers/state-path');

const FIXTURES = path.join(__dirname, '..', 'fixtures', 'transcripts');

describe('Gemini CLI post-commit flow', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepo();
    dir = repo.dir;
    cleanup = repo.cleanup;
  });

  afterEach(() => cleanup());

  it('tracks the active transcript on AfterTool and attaches its delta on post-commit', () => {
    const transcript = path.join(dir, 'gemini-session.jsonl');
    fs.copyFileSync(path.join(FIXTURES, 'gemini-session.jsonl'), transcript);

    runHook('gemini-post-tool.sh', {
      tool_name: 'replace',
      transcript_path: transcript,
      session_id: 'gem-commit-1',
      cwd: dir,
    }, { cwd: dir });

    assert.ok(fs.existsSync(getToolPaths(dir, 'gemini').activeFile));

    makeCommit(dir, 'gemini active delta commit');
    const result = runHook('post-commit.sh', '', { cwd: dir });
    assert.strictEqual(result.exitCode, 0);

    const note = readGitNote(dir);
    assert.ok(note);
    assert.strictEqual(note.sessions.length, 1);
    assert.strictEqual(note.sessions[0].session_id, 'gem-commit-1');
    assert.strictEqual(note.sessions[0].input_tokens, 500);
    assert.strictEqual(note.sessions[0].output_tokens, 250);

    const mainPy = note.ai_files.find((file) => file.file === 'src/main.py');
    assert.ok(mainPy);
    assert.strictEqual(mainPy.ai_lines_added, 2);
    assert.strictEqual(mainPy.ai_lines_removed, 1);

    const checkpoint = JSON.parse(fs.readFileSync(getToolPaths(dir, 'gemini').checkpointFile, 'utf8'));
    assert.strictEqual(checkpoint.transcript_path, transcript);
    assert.strictEqual(checkpoint.session_id, 'gem-commit-1');
    assert.strictEqual(checkpoint.last_line, 6);
  });

  it('SessionEnd writes only the leftover delta after post-commit checkpointing', () => {
    const transcript = path.join(dir, 'gemini-live-session.jsonl');
    fs.copyFileSync(path.join(FIXTURES, 'gemini-session.jsonl'), transcript);

    runHook('gemini-post-tool.sh', {
      tool_name: 'replace',
      transcript_path: transcript,
      session_id: 'gem-commit-2',
      cwd: dir,
    }, { cwd: dir });

    makeCommit(dir, 'gemini checkpoint commit');
    runHook('post-commit.sh', '', { cwd: dir });

    fs.appendFileSync(transcript, '\n' + [
      JSON.stringify({ type: 'human', message: { content: 'one more gemini change' } }),
      JSON.stringify({ type: 'message_update', model: 'gemini-2.5-pro', tokens: { input: 50, output: 25 } }),
      JSON.stringify({ type: 'tool_call', tool_name: 'write_file', args: { file_path: 'src/leftover.py', content: 'x\ny' } }),
    ].join('\n'));

    const stopResult = runHook('gemini-stop.sh', {
      transcript_path: transcript,
      session_id: 'gem-commit-2',
      cwd: dir,
      hook_event_name: 'SessionEnd',
    }, { cwd: dir });
    assert.strictEqual(stopResult.exitCode, 0);

    const note = readGitNote(dir);
    assert.ok(note);
    assert.strictEqual(note.sessions.length, 1);

    const session = note.sessions[0];
    assert.strictEqual(session.session_id, 'gem-commit-2');
    assert.strictEqual(session.input_tokens, 550);
    assert.strictEqual(session.output_tokens, 275);
    assert.strictEqual(session.turns, 3);
    assert.strictEqual(session.api_calls, 3);

    const configPy = note.ai_files.find((file) => file.file === 'src/config.py');
    assert.ok(configPy);
    assert.strictEqual(configPy.ai_lines_added, 3);
    assert.strictEqual(configPy.ai_lines_removed, 0);

    const leftoverPy = note.ai_files.find((file) => file.file === 'src/leftover.py');
    assert.ok(leftoverPy);
    assert.strictEqual(leftoverPy.ai_lines_added, 2);
    assert.strictEqual(leftoverPy.ai_lines_removed, 0);

    const checkpoint = JSON.parse(fs.readFileSync(getToolPaths(dir, 'gemini').checkpointFile, 'utf8'));
    assert.strictEqual(checkpoint.last_line, 9);
    assert.ok(!fs.existsSync(getToolPaths(dir, 'gemini').activeFile));
  });
});
