const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createTestRepo, readGitNote, makeCommit } = require('../helpers/git-repo');
const { runHook } = require('../helpers/run-hook');

const FIXTURES = path.join(__dirname, '..', 'fixtures', 'transcripts');

describe('Windsurf post-commit flow', () => {
  let dir, cleanup;

  beforeEach(() => {
    const repo = createTestRepo();
    dir = repo.dir;
    cleanup = repo.cleanup;
  });

  afterEach(() => cleanup());

  it('attaches Windsurf transcript delta on post-commit', () => {
    const transcript = path.join(dir, 'windsurf-session.jsonl');
    fs.copyFileSync(path.join(FIXTURES, 'windsurf-session.jsonl'), transcript);

    runHook('windsurf-stop.sh', { transcript_path: transcript, trajectory_id: 'traj-1', cwd: dir }, { cwd: dir });

    makeCommit(dir, 'windsurf active delta commit');
    const result = runHook('post-commit.sh', '', { cwd: dir });
    assert.strictEqual(result.exitCode, 0);

    const note = readGitNote(dir);
    assert.ok(note);
    assert.strictEqual(note.sessions.length, 1);

    const session = note.sessions[0];
    assert.strictEqual(session.session_id, 'traj-1');
    assert.strictEqual(session.tool, 'windsurf');
    assert.strictEqual(session.input_tokens, 0);
    assert.strictEqual(session.output_tokens, 0);
    assert.strictEqual(session.estimated_cost, 0);
    assert.strictEqual(session.turns, 1);
    assert.strictEqual(session.api_calls, 1);

    const file = note.ai_files.find((entry) => entry.file === 'src/index.ts');
    assert.ok(file);
    assert.strictEqual(file.ai_lines_added, 2);
    assert.strictEqual(file.ai_lines_removed, 1);

    const checkpoint = JSON.parse(fs.readFileSync(path.join(dir, '.git', 'gitprint-windsurf-checkpoint.json'), 'utf8'));
    assert.strictEqual(checkpoint.transcript_path, transcript);
    assert.strictEqual(checkpoint.session_id, 'traj-1');
    assert.strictEqual(checkpoint.last_line, 2);
  });

  it('only attaches new Windsurf transcript delta after checkpoint', () => {
    const transcript = path.join(dir, 'windsurf-live-session.jsonl');
    fs.copyFileSync(path.join(FIXTURES, 'windsurf-session.jsonl'), transcript);

    runHook('windsurf-stop.sh', { transcript_path: transcript, trajectory_id: 'traj-2', cwd: dir }, { cwd: dir });
    makeCommit(dir, 'windsurf checkpoint commit');
    runHook('post-commit.sh', '', { cwd: dir });

    fs.appendFileSync(transcript, '\n' + [
      JSON.stringify({ type: 'human', message: { content: 'create leftover file' } }),
      JSON.stringify({
        type: 'assistant',
        role: 'assistant',
        content: [
          {
            type: 'tool_use',
            name: 'Write',
            input: { file_path: 'src/leftover.ts', content: 'a\nb\nc' },
          },
        ],
      }),
    ].join('\n'));

    runHook('windsurf-stop.sh', { transcript_path: transcript, trajectory_id: 'traj-2', cwd: dir }, { cwd: dir });
    makeCommit(dir, 'windsurf second commit');
    runHook('post-commit.sh', '', { cwd: dir });

    const note = readGitNote(dir);
    assert.ok(note);
    assert.strictEqual(note.sessions.length, 1);
    assert.strictEqual(note.sessions[0].session_id, 'traj-2');
    assert.strictEqual(note.sessions[0].turns, 1);
    assert.strictEqual(note.sessions[0].api_calls, 1);

    const leftoverFile = note.ai_files.find((entry) => entry.file === 'src/leftover.ts');
    assert.ok(leftoverFile);
    assert.strictEqual(leftoverFile.ai_lines_added, 3);
    assert.strictEqual(leftoverFile.ai_lines_removed, 0);

    const oldFile = note.ai_files.find((entry) => entry.file === 'src/index.ts');
    assert.ok(!oldFile);
  });
});
