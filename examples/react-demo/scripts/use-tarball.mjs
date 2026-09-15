#!/usr/bin/env node
// Switch the demo's OCR SDK dependency to the LOCAL TARBALL snapshot.
// Usage: npm run sdk:tarball
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const demoDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pkgPath = path.join(demoDir, 'package.json');
const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));

const bridgeDir = path.resolve(demoDir, '../../web-sdk-bridge');
const scope = '@gunturpukis/ocr-scanner-react';

// Re-pack the bridge so the tarball always reflects the latest source.
const pack = spawnSync('npm', ['pack'], { cwd: bridgeDir, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] });
if (pack.status !== 0) {
  console.error('npm pack failed in', bridgeDir);
  process.exit(1);
}
const tgz = `${bridgeDir}/${pack.stdout.trim().split('\n').pop()}`;
if (!existsSync(tgz)) {
  console.error('Expected tarball not found:', tgz);
  process.exit(1);
}

pkg.dependencies[scope] = `file:${tgz}`;
writeFileSync(pkgPath, `${JSON.stringify(pkg, null, 2)}\n`);

console.log(`dependency set to: ${scope}@file:${tgz}`);
console.log('running npm install...');
const inst = spawnSync('npm', ['install', '--no-fund', '--no-audit'], { cwd: demoDir, stdio: 'inherit' });
process.exit(inst.status ?? 1);
