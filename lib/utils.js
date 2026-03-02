// Gitprint — Shared utilities
// Pure functions used by both bin/cli.js and tests

// ─── Cost estimation ($ per million tokens) ───
const PRICING = {
  'opus':   { input: 15, output: 75, cache_read: 1.50, cache_creation: 18.75 },
  'sonnet': { input: 3,  output: 15, cache_read: 0.30, cache_creation: 3.75 },
  'haiku':  { input: 1,  output: 5,  cache_read: 0.10, cache_creation: 1.25 },
};

function matchPricing(modelName) {
  const ml = modelName.toLowerCase();
  if (ml.includes('opus')) return PRICING.opus;
  if (ml.includes('sonnet')) return PRICING.sonnet;
  if (ml.includes('haiku')) return PRICING.haiku;
  return PRICING.sonnet;
}

function sessionCost(s) {
  if (s.estimated_cost != null) return s.estimated_cost;
  let cost = 0;
  for (const [model, info] of Object.entries(s.models || {})) {
    const p = matchPricing(model);
    cost += (info.input_tokens / 1e6) * p.input;
    cost += (info.output_tokens / 1e6) * p.output;
  }
  const dm = Object.keys(s.models || {})[0] || '';
  const dp = matchPricing(dm);
  cost += ((s.cache_creation_tokens || 0) / 1e6) * dp.cache_creation;
  cost += ((s.cache_read_tokens || 0) / 1e6) * dp.cache_read;
  return cost;
}

const fmt = n => n > 1000 ? `${(n/1000).toFixed(1)}k` : String(n);
const fmtCost = c => c < 0.01 ? `$${c.toFixed(4)}` : `$${c.toFixed(2)}`;

const countLines = (str) => {
  if (!str) return 0;
  const s = String(str);
  return s.length === 0 ? 0 : s.split('\n').length;
};

const getToolName = (t) => {
  const names = {
    'claude-code': 'Claude Code',
    'gemini': 'Gemini CLI',
    'augment': 'Augment Code',
    'copilot': 'Copilot',
    'opencode': 'OpenCode',
  };
  return names[t] || t.charAt(0).toUpperCase() + t.slice(1);
};

module.exports = { PRICING, matchPricing, sessionCost, fmt, fmtCost, countLines, getToolName };
