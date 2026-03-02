const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const { PRICING, matchPricing, sessionCost, fmt, fmtCost, countLines, getToolName } = require('../../lib/utils');

describe('matchPricing', () => {
  it('matches opus model', () => {
    assert.deepStrictEqual(matchPricing('claude-opus-4-6'), PRICING.opus);
  });
  it('matches sonnet model', () => {
    assert.deepStrictEqual(matchPricing('claude-sonnet-4-6'), PRICING.sonnet);
  });
  it('matches haiku model', () => {
    assert.deepStrictEqual(matchPricing('claude-haiku-4-5'), PRICING.haiku);
  });
  it('defaults to sonnet for unknown model', () => {
    assert.deepStrictEqual(matchPricing('unknown-model'), PRICING.sonnet);
  });
  it('is case-insensitive', () => {
    assert.deepStrictEqual(matchPricing('Claude-Opus-4'), PRICING.opus);
  });
  it('matches partial model names', () => {
    assert.deepStrictEqual(matchPricing('some-opus-variant'), PRICING.opus);
  });
});

describe('sessionCost', () => {
  it('returns estimated_cost when present', () => {
    assert.strictEqual(sessionCost({ estimated_cost: 1.5 }), 1.5);
  });
  it('returns estimated_cost of 0 when explicitly set', () => {
    assert.strictEqual(sessionCost({ estimated_cost: 0 }), 0);
  });
  it('calculates from model token counts when no estimated_cost', () => {
    const s = {
      models: { 'claude-sonnet-4-6': { input_tokens: 1000000, output_tokens: 1000000 } },
      cache_creation_tokens: 0,
      cache_read_tokens: 0,
    };
    // 1M input * 3/1M + 1M output * 15/1M = 3 + 15 = 18
    assert.strictEqual(sessionCost(s), 18);
  });
  it('adds cache costs using dominant model pricing', () => {
    const s = {
      models: { 'claude-sonnet-4-6': { input_tokens: 0, output_tokens: 0 } },
      cache_creation_tokens: 1000000,
      cache_read_tokens: 1000000,
    };
    // cache_creation: 1M * 3.75/1M = 3.75, cache_read: 1M * 0.30/1M = 0.30
    assert.strictEqual(sessionCost(s), 4.05);
  });
  it('returns 0 for empty session', () => {
    assert.strictEqual(sessionCost({}), 0);
  });
  it('handles session with no models', () => {
    const s = { cache_creation_tokens: 0, cache_read_tokens: 0 };
    assert.strictEqual(sessionCost(s), 0);
  });
  it('uses opus pricing for cache when dominant model is opus', () => {
    const s = {
      models: { 'claude-opus-4-6': { input_tokens: 1000000, output_tokens: 0 } },
      cache_creation_tokens: 1000000,
      cache_read_tokens: 0,
    };
    // input: 1M * 15/1M = 15, cache_creation: 1M * 18.75/1M = 18.75
    assert.strictEqual(sessionCost(s), 33.75);
  });
});

describe('fmt', () => {
  it('formats small numbers as-is', () => {
    assert.strictEqual(fmt(500), '500');
  });
  it('formats zero', () => {
    assert.strictEqual(fmt(0), '0');
  });
  it('formats thousands with k suffix', () => {
    assert.strictEqual(fmt(1500), '1.5k');
  });
  it('formats exactly 1000 as-is', () => {
    assert.strictEqual(fmt(1000), '1000');
  });
  it('formats 1001 with k suffix', () => {
    assert.strictEqual(fmt(1001), '1.0k');
  });
  it('formats large numbers', () => {
    assert.strictEqual(fmt(250000), '250.0k');
  });
});

describe('fmtCost', () => {
  it('formats small costs with 4 decimals', () => {
    assert.strictEqual(fmtCost(0.005), '$0.0050');
  });
  it('formats zero with 4 decimals', () => {
    assert.strictEqual(fmtCost(0), '$0.0000');
  });
  it('formats larger costs with 2 decimals', () => {
    assert.strictEqual(fmtCost(1.23), '$1.23');
  });
  it('formats exactly 0.01 with 2 decimals', () => {
    assert.strictEqual(fmtCost(0.01), '$0.01');
  });
});

describe('countLines', () => {
  it('returns 0 for null', () => {
    assert.strictEqual(countLines(null), 0);
  });
  it('returns 0 for undefined', () => {
    assert.strictEqual(countLines(undefined), 0);
  });
  it('returns 0 for empty string', () => {
    assert.strictEqual(countLines(''), 0);
  });
  it('returns 1 for single line', () => {
    assert.strictEqual(countLines('one line'), 1);
  });
  it('returns 2 for two lines', () => {
    assert.strictEqual(countLines('a\nb'), 2);
  });
  it('returns 3 for three lines', () => {
    assert.strictEqual(countLines('a\nb\nc'), 3);
  });
  it('coerces numbers to strings', () => {
    assert.strictEqual(countLines(123), 1);
  });
  it('returns 0 for false', () => {
    assert.strictEqual(countLines(false), 0);
  });
});

describe('getToolName', () => {
  it('maps claude-code', () => {
    assert.strictEqual(getToolName('claude-code'), 'Claude Code');
  });
  it('maps gemini', () => {
    assert.strictEqual(getToolName('gemini'), 'Gemini CLI');
  });
  it('maps augment', () => {
    assert.strictEqual(getToolName('augment'), 'Augment Code');
  });
  it('maps copilot', () => {
    assert.strictEqual(getToolName('copilot'), 'Copilot');
  });
  it('maps opencode', () => {
    assert.strictEqual(getToolName('opencode'), 'OpenCode');
  });
  it('capitalizes unknown tools', () => {
    assert.strictEqual(getToolName('windsurf'), 'Windsurf');
  });
  it('capitalizes cursor', () => {
    assert.strictEqual(getToolName('cursor'), 'Cursor');
  });
});
