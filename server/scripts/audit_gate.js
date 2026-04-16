#!/usr/bin/env node

const { execFileSync } = require('child_process');

function runJson(command, args) {
  try {
    const output = execFileSync(command, args, {
      cwd: process.cwd(),
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return JSON.parse(output);
  } catch (error) {
    const stdout = error && typeof error === 'object' ? error.stdout : '';
    if (typeof stdout === 'string' && stdout.trim().startsWith('{')) {
      return JSON.parse(stdout);
    }
    throw error;
  }
}

function normalizeVersion(raw) {
  return String(raw || '')
    .trim()
    .replace(/^v/i, '')
    .split('-')[0];
}

function compareVersions(a, b) {
  const left = normalizeVersion(a).split('.').map((part) => Number(part || 0));
  const right = normalizeVersion(b).split('.').map((part) => Number(part || 0));
  const maxLength = Math.max(left.length, right.length);
  for (let index = 0; index < maxLength; index += 1) {
    const leftPart = left[index] || 0;
    const rightPart = right[index] || 0;
    if (leftPart > rightPart) return 1;
    if (leftPart < rightPart) return -1;
  }
  return 0;
}

function collectPackageVersions(tree, packageName, acc = new Set()) {
  if (!tree || typeof tree !== 'object') return acc;
  const dependencies =
    tree.dependencies && typeof tree.dependencies === 'object'
      ? tree.dependencies
      : {};
  for (const [name, node] of Object.entries(dependencies)) {
    if (name === packageName && node && typeof node === 'object') {
      const version = normalizeVersion(node.version);
      if (version) acc.add(version);
    }
    collectPackageVersions(node, packageName, acc);
  }
  return acc;
}

function severityRank(raw) {
  switch (String(raw || '').toLowerCase()) {
    case 'critical':
      return 4;
    case 'high':
      return 3;
    case 'moderate':
      return 2;
    case 'low':
      return 1;
    default:
      return 0;
  }
}

function isResolvedPathToRegexp(vulnerability, packageTree) {
  if (!vulnerability || vulnerability.name !== 'path-to-regexp') {
    return false;
  }
  const versions = Array.from(
    collectPackageVersions(packageTree, 'path-to-regexp'),
  );
  if (versions.length === 0) return false;
  return versions.every((version) => compareVersions(version, '0.1.13') >= 0);
}

function main() {
  const audit = runJson('npm', ['audit', '--omit=dev', '--json']);
  const tree = runJson('npm', ['ls', '--all', '--json']);
  const vulnerabilities =
    audit.vulnerabilities && typeof audit.vulnerabilities === 'object'
      ? audit.vulnerabilities
      : {};

  const unresolved = [];
  for (const vulnerability of Object.values(vulnerabilities)) {
    if (!vulnerability || typeof vulnerability !== 'object') continue;
    if (isResolvedPathToRegexp(vulnerability, tree)) {
      continue;
    }
    if (severityRank(vulnerability.severity) >= severityRank('high')) {
      unresolved.push(vulnerability);
    }
  }

  if (unresolved.length > 0) {
    console.error(
      JSON.stringify(
        {
          ok: false,
          unresolved: unresolved.map((item) => ({
            name: item.name,
            severity: item.severity,
            via: item.via,
          })),
        },
        null,
        2,
      ),
    );
    process.exit(1);
  }

  console.log(
    JSON.stringify(
      {
        ok: true,
        ignored: Object.values(vulnerabilities)
          .filter(
            (item) => item && typeof item === 'object' &&
                isResolvedPathToRegexp(item, tree),
          )
          .map((item) => item.name),
        summary: audit.metadata?.vulnerabilities || {},
      },
      null,
      2,
    ),
  );
}

main();
