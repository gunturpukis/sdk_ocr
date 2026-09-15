#!/usr/bin/env node
// Switch the demo's OCR SDK dependency to the REGISTRY version.
// - If @gunturpukis/ocr-scanner-react exists on npm: sets dep to ^latest and installs.
// - If it 404s (not published yet): reverts package.json to the local tarball
//   and leaves the demo untouched so `npm run dev` keeps working.
// Usage: npm run sdk:registry
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const demoDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pkgPath = path.join(demoDir, 'package.json');
const scope = '@gunturpukis/ocr-scanner-react';

const readPkg = () => JSON.parse(readFileSync(pkgPath, 'utf8'));
const writeDep = (spec) => {
  const pkg = readPkg();
  pkg.dependencies[scope] = spec;
  writeFileSync(pkgPath, `${JSON.stringify(pkg, null, 2)}\n`);
};

const view = spawnSync('npm', ['view', scope, 'version', '--json'], {
  encoding: 'utf8',
  stdio: ['ignore', 'pipe', 'ignore'],
});

if (view.status !== 0 || !view.stdout.trim()) {
  console.log(`${scope} is not on the npm registry yet (npm view failed).`);
  console.log('Publish it first (see web-sdk-bridge/README.md), or use: npm run sdk:tarball');
  process.exit(1);
}

const latest = JSON.parse(view.stdout);
console.log(`registry version found: ${scope}@${latest}`);

writeDep(`^${latest}`);
console.log('running npm install...');
const inst = spawnSync('npm', ['install', '--no-fund', '--no-audit'], { cwd: demoDir, stdio: 'inherit' });
if ((inst.status ?? 1) !== 0) {
  console.error('npm install failed — reverting to local tarball.');
  writeDep('file:../../web-sdk-bridge/gunturpukis-ocr-scanner-react-0.1.0.tgz');
  spawnSync('npm', ['install', '--no-fund', '--no-audit'], { cwd: demoDir, stdio: 'inherit' });
  process.exit(1);
}
console.log(`done: demo now uses ${scope}@^${latest} from the npm registry.`);
