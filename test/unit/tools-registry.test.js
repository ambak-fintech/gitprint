const { describe, it, before } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

// Extract TOOLS array from cli.js source by evaluating just the relevant parts
function loadTools() {
  const src = fs.readFileSync(path.join(__dirname, '..', '..', 'bin', 'cli.js'), 'utf8');

  // Find the TOOLS array declaration
  const toolsMatch = src.match(/const TOOLS = \[([\s\S]*?)\n\];/);
  if (!toolsMatch) throw new Error('Could not find TOOLS array in cli.js');

  // We need execSync, fs, path, os for the detect functions
  const { execSync } = require('child_process');
  const os = require('os');

  // Evaluate with necessary context
  const fn = new Function('fs', 'path', 'os', 'execSync', `
    const TOOLS = [${toolsMatch[1]}
    ];
    return TOOLS;
  `);

  return fn(fs, path, os, execSync);
}

let TOOLS;

describe('TOOLS registry', () => {
  before(() => {
    TOOLS = loadTools();
  });

  it('has exactly 7 tool entries', () => {
    assert.strictEqual(TOOLS.length, 7);
  });

  it('only claude-code has required=true', () => {
    const required = TOOLS.filter(t => t.required);
    assert.strictEqual(required.length, 1);
    assert.strictEqual(required[0].id, 'claude-code');
  });

  it('each tool has required fields', () => {
    for (const tool of TOOLS) {
      assert.ok(tool.id, `tool missing id`);
      assert.ok(tool.name, `${tool.id} missing name`);
      assert.ok(typeof tool.detect === 'function', `${tool.id} missing detect function`);
      assert.ok(Array.isArray(tool.hooks), `${tool.id} missing hooks array`);
      assert.ok(tool.config, `${tool.id} missing config`);
    }
  });

  it('all tool IDs are unique', () => {
    const ids = TOOLS.map(t => t.id);
    assert.strictEqual(new Set(ids).size, ids.length);
  });

  it('expected tool IDs are present', () => {
    const ids = TOOLS.map(t => t.id);
    for (const expected of ['claude-code', 'cursor', 'copilot', 'gemini', 'windsurf', 'augment', 'opencode']) {
      assert.ok(ids.includes(expected), `missing tool: ${expected}`);
    }
  });

  it('every hook src file exists in templates/', () => {
    const templatesDir = path.join(__dirname, '..', '..', 'templates');
    for (const tool of TOOLS) {
      for (const hook of tool.hooks) {
        const srcPath = path.join(templatesDir, hook.src);
        assert.ok(fs.existsSync(srcPath), `${tool.id}: template ${hook.src} not found`);
      }
    }
  });

  it('config types are valid', () => {
    const validTypes = ['settings-json', 'hooks-json', 'standalone-json', 'none'];
    for (const tool of TOOLS) {
      assert.ok(validTypes.includes(tool.config.type), `${tool.id} has invalid config type: ${tool.config.type}`);
    }
  });

  it('all detect() functions are callable without error', () => {
    for (const tool of TOOLS) {
      assert.doesNotThrow(() => tool.detect('/tmp/nonexistent'));
    }
  });

  it('claude-code detect() always returns true', () => {
    assert.strictEqual(TOOLS.find(t => t.id === 'claude-code').detect('/tmp/anything'), true);
  });

  it('each tool has addPaths array', () => {
    for (const tool of TOOLS) {
      assert.ok(Array.isArray(tool.addPaths), `${tool.id} missing addPaths array`);
      assert.ok(tool.addPaths.length > 0, `${tool.id} has empty addPaths`);
    }
  });

  it('doctorChecks use valid check types', () => {
    const validCheckTypes = ['file-exec', 'file-exists', 'dry-run', 'settings-json', 'hooks-json', 'standalone-json-check'];
    for (const tool of TOOLS) {
      for (const check of (tool.doctorChecks || [])) {
        assert.ok(validCheckTypes.includes(check.type), `${tool.id} has invalid check type: ${check.type}`);
      }
    }
  });

  it('optional tools have detectHint', () => {
    for (const tool of TOOLS) {
      if (!tool.required) {
        assert.ok(tool.detectHint, `${tool.id} missing detectHint`);
      }
    }
  });

  it('opencode plugin has noExec flag', () => {
    const opencode = TOOLS.find(t => t.id === 'opencode');
    assert.ok(opencode.hooks[0].noExec, 'opencode plugin should have noExec');
  });

  it('two-hook tools have exactly 2 hooks', () => {
    for (const id of ['copilot', 'augment']) {
      const tool = TOOLS.find(t => t.id === id);
      assert.strictEqual(tool.hooks.length, 2, `${id} should have 2 hooks`);
    }
  });
});
