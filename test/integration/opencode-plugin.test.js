const { describe, it, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const { createTestRepo, readGitNote, GIT_ENV } = require('../helpers/git-repo');

const PLUGIN_PATH = path.join(__dirname, '..', '..', 'templates', 'opencode-plugin.js');

function createMockApi() {
  const handlers = {};
  return {
    on(event, handler) {
      if (!handlers[event]) handlers[event] = [];
      handlers[event].push(handler);
    },
    emit(event, data) {
      for (const h of (handlers[event] || [])) h(data);
    },
    async emitAsync(event, data) {
      for (const h of (handlers[event] || [])) await h(data);
    },
    handlers,
  };
}

describe('OpenCode plugin (opencode-plugin.js)', () => {
  let plugin, api;

  beforeEach(() => {
    delete require.cache[require.resolve(PLUGIN_PATH)];
    plugin = require(PLUGIN_PATH);
    api = createMockApi();
    plugin.setup(api);
  });

  it('has name "gitprint"', () => {
    assert.strictEqual(plugin.name, 'gitprint');
  });

  it('setup registers 3 event handlers', () => {
    assert.ok(api.handlers['tool.execute.after']);
    assert.ok(api.handlers['message.after']);
    assert.ok(api.handlers['session.idle']);
  });

  it('tracks edit tool via tool.execute.after', () => {
    assert.doesNotThrow(() => {
      api.emit('tool.execute.after', {
        tool: 'edit',
        input: { file_path: 'src/app.js', old_string: 'old', new_string: 'new\nline' },
      });
    });
  });

  it('tracks write tool via tool.execute.after', () => {
    assert.doesNotThrow(() => {
      api.emit('tool.execute.after', {
        tool: 'write',
        input: { file_path: 'src/new.js', content: 'a\nb\nc' },
      });
    });
  });

  it('tracks multi_edit tool via tool.execute.after', () => {
    assert.doesNotThrow(() => {
      api.emit('tool.execute.after', {
        tool: 'multi_edit',
        input: {
          file_path: 'src/app.js',
          edits: [
            { old_string: 'a', new_string: 'b\nc' },
            { old_string: 'x', new_string: 'y' },
          ],
        },
      });
    });
  });

  it('skips unknown tools without error', () => {
    assert.doesNotThrow(() => {
      api.emit('tool.execute.after', {
        tool: 'read',
        input: { file_path: 'src/app.js' },
      });
    });
  });

  it('accumulates tokens via message.after', () => {
    assert.doesNotThrow(() => {
      api.emit('message.after', {
        usage: { input_tokens: 100, output_tokens: 50 },
        model: 'test-model',
      });
      api.emit('message.after', {
        usage: { input_tokens: 200, output_tokens: 100 },
        model: 'test-model',
      });
    });
  });

  it('captures session_id from message.after', () => {
    assert.doesNotThrow(() => {
      api.emit('message.after', {
        session_id: 'oc-session-1',
        usage: { input_tokens: 10, output_tokens: 5 },
      });
    });
  });

  describe('session.idle (with git repo)', () => {
    let dir, cleanup, originalCwd;

    beforeEach(() => {
      const repo = createTestRepo();
      dir = repo.dir;
      cleanup = repo.cleanup;
      originalCwd = process.cwd();

      delete require.cache[require.resolve(PLUGIN_PATH)];
      plugin = require(PLUGIN_PATH);
      api = createMockApi();
      process.chdir(dir);
      Object.assign(process.env, GIT_ENV);
      plugin.setup(api);
    });

    afterEach(() => {
      process.chdir(originalCwd);
      cleanup();
    });

    it('writes git note on session.idle', async () => {
      api.emit('tool.execute.after', {
        tool: 'edit',
        input: { file_path: 'src/app.js', old_string: 'old', new_string: 'new\nline' },
      });
      api.emit('message.after', {
        session_id: 'oc-1',
        usage: { input_tokens: 100, output_tokens: 50 },
        model: 'test-model',
      });
      await api.emitAsync('session.idle');
      const note = readGitNote(dir);
      assert.ok(note);
      assert.strictEqual(note.sessions[0].tool, 'opencode');
      assert.strictEqual(note.sessions[0].session_id, 'oc-1');
      assert.strictEqual(note.sessions[0].input_tokens, 100);
      const file = note.ai_files.find(f => f.file === 'src/app.js');
      assert.ok(file);
      assert.strictEqual(file.ai_lines_added, 2);
    });

    it('resets counters after writing', async () => {
      api.emit('tool.execute.after', {
        tool: 'write',
        input: { file_path: 'src/reset.js', content: 'line1\nline2' },
      });
      api.emit('message.after', {
        session_id: 'oc-reset',
        usage: { input_tokens: 50, output_tokens: 25 },
      });
      await api.emitAsync('session.idle');
      await api.emitAsync('session.idle');
      const note = readGitNote(dir);
      assert.strictEqual(note.sessions.length, 1);
    });

    it('skips when no data', async () => {
      await api.emitAsync('session.idle');
      const note = readGitNote(dir);
      assert.strictEqual(note, null);
    });
  });
});
