// Gitprint — OpenCode Plugin
// Auto-loaded from .opencode/plugins/gitprint.js
// Tracks AI tool file edits and writes Git Notes on session idle

const { execSync } = require('child_process');
const path = require('path');

const DEBUG = process.env.GITPRINT_DEBUG === '1';
const log = (...args) => { if (DEBUG) console.error('[gitprint:opencode]', ...args); };
const logErr = (...args) => { console.error('[gitprint:opencode] ERROR:', ...args); };

module.exports = {
  name: 'gitprint',

  setup(api) {
    const fileStats = {};
    let inputTokens = 0;
    let outputTokens = 0;
    let cacheCreation = 0;
    let cacheRead = 0;
    let turns = 0;
    const models = {};
    let sessionId = 'unknown';

    const countLines = (str) => {
      if (!str) return 0;
      const s = String(str);
      return s.length === 0 ? 0 : s.split('\n').length;
    };

    const trackFile = (fp, added, removed) => {
      if (!fp) return;
      fp = fp.replace(/^\.\//, '');
      const cwd = process.cwd();
      if (fp.startsWith(cwd + '/')) fp = fp.slice(cwd.length + 1);
      if (fp.includes('node_modules')) return;
      if (!fileStats[fp]) fileStats[fp] = { added: 0, removed: 0 };
      fileStats[fp].added += added;
      fileStats[fp].removed += removed;
    };

    // Track tool executions for file edits
    api.on('tool.execute.after', (event) => {
      try {
        const name = (event.tool || event.name || '').toLowerCase();
        const input = event.input || event.args || {};

        // edit / str_replace
        if (/^(edit|str_replace|str_replace_editor|replace)$/.test(name)) {
          const fp = input.file_path || input.path || input.filePath;
          const oldStr = input.old_str || input.old_string || input.oldStr || '';
          const newStr = input.new_str || input.new_string || input.newStr || input.replacement || '';
          trackFile(fp, countLines(newStr), countLines(oldStr));
          log('tracked edit:', fp);
        }

        // write / create
        if (/^(write|create|file_write|create_file|write_file)$/.test(name)) {
          const fp = input.file_path || input.path || input.filePath;
          trackFile(fp, countLines(input.content || input.file_text || ''), 0);
          log('tracked write:', fp);
        }

        // multi_edit
        if (/^(multi_edit|multiedit)$/.test(name)) {
          const fp = input.file_path || input.path || input.filePath;
          for (const edit of (input.edits || [])) {
            trackFile(fp, countLines(edit.new_str || edit.new_string || ''), countLines(edit.old_str || edit.old_string || ''));
          }
          log('tracked multi_edit:', fp);
        }
      } catch (e) {
        logErr('tool.execute.after handler failed:', e.message);
      }
    });

    // Track token usage if available
    api.on('message.after', (event) => {
      try {
        const usage = event.usage || event.message?.usage;
        if (usage) {
          const inp = usage.input_tokens || usage.prompt_tokens || 0;
          const out = usage.output_tokens || usage.completion_tokens || 0;
          const cc = usage.cache_creation_input_tokens || 0;
          const cr = usage.cache_read_input_tokens || 0;

          inputTokens += inp;
          outputTokens += out;
          cacheCreation += cc;
          cacheRead += cr;
          turns++;

          const model = event.model || 'unknown';
          if (!models[model]) models[model] = { input_tokens: 0, output_tokens: 0, turns: 0 };
          models[model].input_tokens += inp + cc + cr;
          models[model].output_tokens += out;
          models[model].turns++;
        }

        // Capture session ID
        if (event.session_id) sessionId = event.session_id;
      } catch (e) {
        logErr('message.after handler failed:', e.message);
      }
    });

    // Write git note on session idle/end
    api.on('session.idle', async () => {
      try {
        const aiFiles = Object.entries(fileStats).map(([file, s]) => ({
          file, ai_lines_added: s.added, ai_lines_removed: s.removed,
        }));

        // Skip if no data
        if (aiFiles.length === 0 && inputTokens === 0 && outputTokens === 0) {
          log('no data to write');
          return;
        }

        const sessionData = {
          session_id: sessionId,
          tool: 'opencode',
          timestamp: new Date().toISOString(),
          input_tokens: inputTokens,
          output_tokens: outputTokens,
          cache_creation_tokens: cacheCreation,
          cache_read_tokens: cacheRead,
          estimated_cost: 0,
          turns,
          models,
          ai_files: aiFiles,
        };

        // Get HEAD SHA
        let headSha;
        try {
          headSha = execSync('git rev-parse HEAD', { encoding: 'utf8' }).trim();
        } catch {
          logErr('not in a git repo or no commits');
          return;
        }

        // Read existing note
        let existingNote = '{}';
        try {
          existingNote = execSync(`git notes --ref=gitprint show ${headSha}`, { encoding: 'utf8' }).trim();
        } catch { /* no existing note */ }

        let data;
        try {
          data = JSON.parse(existingNote);
        } catch {
          data = {};
        }
        if (!data.sessions) data.sessions = [];
        if (!data.ai_files) data.ai_files = [];

        // Merge file stats
        const fileMap = {};
        for (const f of data.ai_files) {
          fileMap[f.file] = { ai_lines_added: f.ai_lines_added || 0, ai_lines_removed: f.ai_lines_removed || 0 };
        }
        for (const f of aiFiles) {
          if (!fileMap[f.file]) fileMap[f.file] = { ai_lines_added: 0, ai_lines_removed: 0 };
          fileMap[f.file].ai_lines_added += f.ai_lines_added || 0;
          fileMap[f.file].ai_lines_removed += f.ai_lines_removed || 0;
        }
        data.ai_files = Object.entries(fileMap).map(([file, s]) => ({
          file, ai_lines_added: s.ai_lines_added, ai_lines_removed: s.ai_lines_removed,
        }));

        // Add session
        const session = { ...sessionData };
        delete session.ai_files;
        const exists = data.sessions.find(s => s.session_id === session.session_id);
        if (!exists) data.sessions.push(session);

        const merged = JSON.stringify(data);

        // Write git note
        try {
          execSync(`git notes --ref=gitprint add -f --file=- ${headSha}`, {
            input: merged,
            stdio: ['pipe', 'pipe', 'pipe'],
          });
          log('note written to', headSha);
        } catch (e) {
          logErr('git notes write failed:', e.message);
          return;
        }

        // Push notes in background (best-effort)
        try {
          const { spawn } = require('child_process');
          const pushProc = spawn('git', ['push', 'origin', 'refs/notes/gitprint'], {
            stdio: 'ignore',
            detached: true,
          });
          pushProc.unref();
          log('push triggered in background');
        } catch {
          log('push failed (may be offline)');
        }

        // Reset counters for next idle cycle
        for (const key of Object.keys(fileStats)) delete fileStats[key];
        inputTokens = 0;
        outputTokens = 0;
        cacheCreation = 0;
        cacheRead = 0;
        turns = 0;
        for (const key of Object.keys(models)) delete models[key];
      } catch (e) {
        logErr('session.idle handler failed:', e.message);
      }
    });
  },
};
