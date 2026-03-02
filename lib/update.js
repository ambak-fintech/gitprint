// Gitprint — Update check + self-update

const https = require('https');
const { execSync } = require('child_process');
const path = require('path');

function getLocalVersion() {
  const pkg = require(path.join(__dirname, '..', 'package.json'));
  return pkg.version;
}

function isNewer(latest, current) {
  const l = latest.split('.').map(Number);
  const c = current.split('.').map(Number);
  for (let i = 0; i < 3; i++) {
    if ((l[i] || 0) > (c[i] || 0)) return true;
    if ((l[i] || 0) < (c[i] || 0)) return false;
  }
  return false;
}

function checkForUpdate() {
  return new Promise((resolve) => {
    try {
      const current = getLocalVersion();
      const req = https.get('https://registry.npmjs.org/@ambak/gitprint/latest', {
        timeout: 2000,
        headers: { 'Accept': 'application/json' },
      }, (res) => {
        let body = '';
        res.on('data', (chunk) => { body += chunk; });
        res.on('end', () => {
          try {
            const data = JSON.parse(body);
            const latest = data.version;
            if (!latest) { resolve(null); return; }
            resolve({
              current,
              latest,
              updateAvailable: isNewer(latest, current),
            });
          } catch { resolve(null); }
        });
      });
      req.on('error', () => resolve(null));
      req.on('timeout', () => { req.destroy(); resolve(null); });
    } catch { resolve(null); }
  });
}

async function runUpdate() {
  const result = await checkForUpdate();
  if (!result) {
    console.log('  Could not check for updates. Try manually:');
    console.log('  npm install -g @ambak/gitprint@latest');
    return;
  }
  if (!result.updateAvailable) {
    console.log(`  Already on latest version (${result.current}).`);
    return;
  }
  console.log(`  Updating ${result.current} → ${result.latest}...`);
  console.log('');
  execSync('npm install -g @ambak/gitprint@latest', { stdio: 'inherit' });
  console.log('');
  console.log(`  Run 'gitprint init' in your repos to update hooks.`);
}

module.exports = { getLocalVersion, isNewer, checkForUpdate, runUpdate };
