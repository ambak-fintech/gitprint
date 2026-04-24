const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createTestRepo, readGitNote, makeCommit } = require('../helpers/git-repo');
const { runHook } = require('../helpers/run-hook');

const FIXTURES = path.join(__dirname, '..', 'fixtures', 'transcripts');

describe('Claude Code post-commit flow', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepo();
    dir = repo.dir;
    cleanup = repo.cleanup;
  });

  afterEach(() => cleanup());

  it('tracks the active transcript on any PostToolUse call and attaches its delta on post-commit', () => {
    const transcript = path.join(dir, 'claude-session.jsonl');
    fs.copyFileSync(path.join(FIXTURES, 'claude-session.jsonl'), transcript);

    runHook('post-tool-use.sh', {
      tool_name: 'Read',
      transcript_path: transcript,
      session_id: 'commit-session-1',
    }, { cwd: dir });

    const activeFile = path.join(dir, '.git', 'gitprint-active.json');
    assert.ok(fs.existsSync(activeFile));

    makeCommit(dir, 'commit with active Claude session');
    const result = runHook('post-commit.sh', '', { cwd: dir });
    assert.strictEqual(result.exitCode, 0);

    const note = readGitNote(dir);
    assert.ok(note);
    assert.strictEqual(note.sessions.length, 1);
    assert.strictEqual(note.sessions[0].session_id, 'commit-session-1');
    assert.strictEqual(note.sessions[0].input_tokens, 1000);

    const appFile = note.ai_files.find((file) => file.file === 'src/app.js');
    assert.ok(appFile);
    assert.strictEqual(appFile.ai_lines_added, 10);
    assert.strictEqual(appFile.ai_lines_removed, 6);

    const checkpoint = JSON.parse(fs.readFileSync(path.join(dir, '.git', 'gitprint-checkpoint.json'), 'utf8'));
    assert.strictEqual(checkpoint.transcript_path, transcript);
    assert.strictEqual(checkpoint.session_id, 'commit-session-1');
    assert.strictEqual(checkpoint.last_line, 4);
  });

  it('stop only merges the leftover delta after post-commit checkpointing', () => {
    const transcript = path.join(dir, 'claude-live-session.jsonl');
    fs.copyFileSync(path.join(FIXTURES, 'claude-session.jsonl'), transcript);

    runHook('post-tool-use.sh', {
      tool_name: 'Edit',
      transcript_path: transcript,
      session_id: 'commit-session-2',
    }, { cwd: dir });

    makeCommit(dir, 'checkpoint Claude work');
    runHook('post-commit.sh', '', { cwd: dir });

    fs.appendFileSync(transcript, '\n' + [
      JSON.stringify({ type: 'human', message: { content: 'one more change' } }),
      JSON.stringify({
        type: 'assistant',
        model: 'claude-sonnet-4-6',
        message: {
          usage: {
            input_tokens: 50,
            output_tokens: 25,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0,
          },
          content: [
            {
              type: 'tool_use',
              name: 'Edit',
              input: {
                file_path: 'src/leftover.js',
                old_string: 'before',
                new_string: 'after\nextra',
              },
            },
          ],
        },
      }),
    ].join('\n'));

    const stopResult = runHook('stop.sh', {
      transcript_path: transcript,
      session_id: 'commit-session-2',
    }, { cwd: dir });
    assert.strictEqual(stopResult.exitCode, 0);

    const note = readGitNote(dir);
    assert.ok(note);
    assert.strictEqual(note.sessions.length, 1);

    const session = note.sessions[0];
    assert.strictEqual(session.session_id, 'commit-session-2');
    assert.strictEqual(session.input_tokens, 1050);
    assert.strictEqual(session.output_tokens, 525);
    assert.strictEqual(session.turns, 3);
    assert.strictEqual(session.api_calls, 3);

    const appFile = note.ai_files.find((file) => file.file === 'src/app.js');
    assert.ok(appFile);
    assert.strictEqual(appFile.ai_lines_added, 10);
    assert.strictEqual(appFile.ai_lines_removed, 6);

    const leftoverFile = note.ai_files.find((file) => file.file === 'src/leftover.js');
    assert.ok(leftoverFile);
    assert.strictEqual(leftoverFile.ai_lines_added, 2);
    assert.strictEqual(leftoverFile.ai_lines_removed, 1);

    const checkpoint = JSON.parse(fs.readFileSync(path.join(dir, '.git', 'gitprint-checkpoint.json'), 'utf8'));
    assert.strictEqual(checkpoint.last_line, 6);
    assert.ok(!fs.existsSync(path.join(dir, '.git', 'gitprint-active.json')));
  });
});
