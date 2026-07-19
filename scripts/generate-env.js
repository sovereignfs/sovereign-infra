#!/usr/bin/env node
// scripts/generate-env.js
//
// Renders apps/<app>/.env from the latest upstream sovereign .env.example
// plus operator-owned values in env.yml (git ignored), then encrypts it to
// apps/<app>/.env.enc via scripts/encrypt-env.sh. Replaces manual .env
// editing and scripts/fetch-env-example.sh (INFRA-011).
//
// Usage:
//   node scripts/generate-env.js sovereign
//   node scripts/generate-env.js sovereign --env-file env.yml
//   node scripts/generate-env.js sovereign --check
//   node scripts/generate-env.js sovereign --no-fetch
//
// Run from the repo root — every path below is relative to it, matching the
// existing scripts/*.sh convention.

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import yaml from 'js-yaml';

const REPO_ROOT = process.cwd();
const UPSTREAM_URL = 'https://raw.githubusercontent.com/sovereignfs/sovereign/main/.env.example';
const SEPARATOR = '# ══ deployment overrides';

// Placeholder tokens that must never survive into a rendered .env — a line
// containing one of these means the operator hasn't supplied a real value
// for whatever key uses it, in env.yml or otherwise.
const PLACEHOLDER_PATTERNS = [
  'YOUR_RUNTIME_DOMAIN',
  'YOUR_AUTH_DOMAIN',
  'YOUR_ROOT_DOMAIN',
  'YOUR_ORG/YOUR_BACKUP_REPO',
  'changeme',
];

// Keys apps/sovereign/.env.example ships blank or placeholder-filled that
// sovereign (or this deployment template) cannot run without. Kept as an
// explicit list — matching "structured and testable" in the roadmap task —
// rather than inferred from the template's blank/placeholder shape, since
// some upstream keys (e.g. SMTP_USER/SMTP_PASS) are blank-but-optional.
const REQUIRED_KEYS = [
  'AUTH_SECRET',
  'SOVEREIGN_ADMIN_KEY',
  'POSTGRES_PASSWORD',
  'NEXT_PUBLIC_RUNTIME_URL',
  'AUTH_BASE_URL',
  'SOVEREIGN_AUTH_PUBLIC_URL',
  'AUTH_COOKIE_DOMAIN',
  'AUTH_WEBAUTHN_RP_ID',
  'AUTH_WEBAUTHN_ORIGIN',
  'BACKUP_GITHUB_TOKEN',
  'BACKUP_GITHUB_REPO',
  'AGE_PUBLIC_KEY',
];

// Matches an active or commented-out `KEY=value` line. Plain prose comments
// (section headers, explanations) never match — they don't have `KEY=`.
const ENV_LINE_RE = /^(#\s*)?([A-Z][A-Z0-9_]*)=(.*)$/;

function usage() {
  return `Usage: node scripts/generate-env.js <app> [options]

Options:
  --env-file <path>   Path to the operator env.yml (default: env.yml)
  --check             Validate env.yml renders a complete .env; write nothing
  --no-fetch          Skip fetching upstream .env.example; use the committed one

Examples:
  node scripts/generate-env.js sovereign
  node scripts/generate-env.js sovereign --env-file env.yml
  node scripts/generate-env.js sovereign --check
  node scripts/generate-env.js sovereign --no-fetch`;
}

function parseArgs(argv) {
  const positional = [];
  const options = { envFile: 'env.yml', check: false, noFetch: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--env-file') {
      const next = argv[++i];
      if (!next) throw new Error('--env-file requires a path argument.');
      options.envFile = next;
    } else if (arg === '--check') {
      options.check = true;
    } else if (arg === '--no-fetch') {
      options.noFetch = true;
    } else if (arg.startsWith('-')) {
      throw new Error(`Unknown option: ${arg}\n\n${usage()}`);
    } else {
      positional.push(arg);
    }
  }
  const [app] = positional;
  if (!app) throw new Error(`Missing <app> argument.\n\n${usage()}`);
  return { app, ...options };
}

/** Load env.yml and flatten apps[app] into a Map<KEY, string value>, with
 * AGE_PUBLIC_KEY falling back to global.agePublicKey when the app section
 * doesn't set its own. */
function loadValues(envFilePath, app) {
  if (!existsSync(envFilePath)) {
    const rel = relative(REPO_ROOT, envFilePath) || envFilePath;
    throw new Error(`${rel} not found. Copy env.example.yml to ${rel} and fill in your values.`);
  }
  const parsed = yaml.load(readFileSync(envFilePath, 'utf8')) ?? {};
  const appSection = parsed.apps?.[app] ?? {};
  const values = new Map();
  for (const [key, value] of Object.entries(appSection)) {
    if (value === null || value === undefined) continue;
    values.set(key, String(value));
  }
  if (!values.has('AGE_PUBLIC_KEY') && parsed.global?.agePublicKey) {
    values.set('AGE_PUBLIC_KEY', String(parsed.global.agePublicKey));
  }
  return values;
}

/** Everything from the separator line onward, verbatim. Throws if the
 * separator is missing — splicing would silently drop deployment overrides. */
function extractDeploymentOverrides(envExampleText) {
  const lines = envExampleText.split('\n');
  const index = lines.findIndex((line) => line.includes(SEPARATOR));
  if (index === -1) {
    throw new Error(
      `Separator line not found in the existing .env.example:\n  ${SEPARATOR}\nCannot safely splice — aborting.`,
    );
  }
  return lines.slice(index).join('\n');
}

async function fetchUpstreamTemplate() {
  const res = await fetch(UPSTREAM_URL);
  if (!res.ok) {
    throw new Error(`Could not fetch ${UPSTREAM_URL}: HTTP ${String(res.status)}`);
  }
  return res.text();
}

function buildEnvExample(upstreamText, localBlock) {
  return [
    '# Sovereign environment configuration.',
    '#',
    '# Upstream section auto-synced from sovereignfs/sovereign/.env.example',
    '# via scripts/generate-env.js — do not edit above the separator line.',
    '# Deployment-specific overrides live below the separator.',
    '#',
    '# To render apps/<app>/.env from this template plus your own secrets,',
    '# fill in env.yml (copy from env.example.yml) and run:',
    '#   node scripts/generate-env.js <app>',
    '',
    upstreamText.trimEnd(),
    '',
    localBlock.trimEnd(),
    '',
  ].join('\n');
}

/** Render the final .env: for each KEY= line (commented or not), an env.yml
 * override always wins and is emitted uncommented; otherwise an already-
 * active default line is kept as-is, and a commented-out, unconfigured
 * optional line is dropped entirely. Non-KEY lines (comments, section
 * headers, blank lines) are dropped — comments may be omitted from the
 * generated file (only env.yml/.env.example need to stay readable). */
function renderEnv(envExampleText, values) {
  // A KEY can legitimately appear more than once — the upstream section sets
  // a local-dev default (e.g. DB_DIALECT=sqlite) and the deployment-overrides
  // block re-declares it for this deployment (DB_DIALECT=postgres). Resolve
  // with a Map keyed by KEY so the *last* occurrence's value wins (matching
  // "deployment overrides win over upstream", since that block is always
  // appended after the upstream section) while each key still emits exactly
  // once, at the position of its *first* occurrence (Map.set on an existing
  // key updates the value without moving it in iteration order) — so, e.g.,
  // AUTH_SECRET stays near the top of the rendered file rather than jumping
  // to wherever its last mention happens to fall.
  const resolved = new Map();
  const usedKeys = new Set();

  for (const line of envExampleText.split('\n')) {
    const match = ENV_LINE_RE.exec(line);
    if (!match) continue;
    const [, commentPrefix, key, defaultValue] = match;
    if (values.has(key)) {
      resolved.set(key, values.get(key));
      usedKeys.add(key);
    } else if (!commentPrefix) {
      resolved.set(key, defaultValue);
    }
    // else: commented-out, unconfigured optional key — omitted from .env.
  }

  const outputLines = [...resolved].map(([key, value]) => `${key}=${value}`);
  const unusedKeys = [...values.keys()].filter((key) => !usedKeys.has(key));
  return { text: outputLines.join('\n') + '\n', activeValues: resolved, unusedKeys };
}

function validate(activeValues) {
  const missing = REQUIRED_KEYS.filter((key) => !(activeValues.get(key) ?? '').trim());
  const placeholders = [];
  for (const [key, value] of activeValues) {
    if (PLACEHOLDER_PATTERNS.some((pattern) => value.includes(pattern))) {
      placeholders.push(key);
    }
  }
  return { missing, placeholders, ok: missing.length === 0 && placeholders.length === 0 };
}

function resolveAgeKeyForEncryption(values) {
  return values.get('AGE_PUBLIC_KEY') ?? process.env.AGE_PUBLIC_KEY ?? '';
}

async function main() {
  const { app, envFile, check, noFetch } = parseArgs(process.argv.slice(2));

  const appDir = join(REPO_ROOT, 'apps', app);
  if (!existsSync(appDir)) {
    throw new Error(`apps/${app} not found. Run from the repo root; check the app name.`);
  }
  const envExamplePath = join(appDir, '.env.example');
  const envPath = join(appDir, '.env');
  const envFilePath = resolve(REPO_ROOT, envFile);

  const values = loadValues(envFilePath, app);

  let envExampleText = readFileSync(envExamplePath, 'utf8');
  let fetched = false;
  let envExampleChanged = false;

  if (!noFetch) {
    const upstreamText = await fetchUpstreamTemplate();
    fetched = true;
    const localBlock = extractDeploymentOverrides(envExampleText);
    const rebuilt = buildEnvExample(upstreamText, localBlock);
    envExampleChanged = rebuilt !== envExampleText;
    envExampleText = rebuilt;
  }

  const { text: renderedEnv, activeValues, unusedKeys } = renderEnv(envExampleText, values);
  const validation = validate(activeValues);

  if (!validation.ok) {
    if (validation.missing.length > 0) {
      console.error(`Missing required values: ${validation.missing.join(', ')}`);
    }
    if (validation.placeholders.length > 0) {
      console.error(`Unresolved placeholders remain for: ${validation.placeholders.join(', ')}`);
    }
    console.error(`\nSet these in ${envFile} and re-run.`);
    process.exitCode = 1;
    return;
  }

  if (check) {
    console.log(`OK — ${envFile} renders a complete .env for "${app}". No files written.`);
    if (unusedKeys.length > 0) {
      console.log(
        `Note: ${unusedKeys.join(', ')} set in ${envFile} but not used by apps/${app}/.env.example.`,
      );
    }
    return;
  }

  if (envExampleChanged) {
    writeFileSync(envExamplePath, envExampleText);
  }
  writeFileSync(envPath, renderedEnv);

  const ageKey = resolveAgeKeyForEncryption(values);
  if (!ageKey) {
    throw new Error(
      'No AGE_PUBLIC_KEY available for encryption — set global.agePublicKey or ' +
        `apps.${app}.AGE_PUBLIC_KEY in ${envFile}, or export AGE_PUBLIC_KEY.`,
    );
  }
  execFileSync('bash', [join(REPO_ROOT, 'scripts', 'encrypt-env.sh'), app], {
    stdio: 'inherit',
    env: { ...process.env, AGE_PUBLIC_KEY: ageKey },
  });

  console.log('');
  console.log('Summary:');
  console.log(`  Upstream template fetched: ${fetched ? 'yes' : 'no (--no-fetch)'}`);
  console.log(`  .env.example changed:      ${envExampleChanged ? 'yes' : 'no'}`);
  console.log(`  .env generated:            apps/${app}/.env`);
  console.log(`  .env.enc generated:        apps/${app}/.env.enc`);
  console.log('  Variables missing:         none');
  if (unusedKeys.length > 0) {
    console.log(`  Note: ${unusedKeys.join(', ')} set in ${envFile} but unused by the template.`);
  }
}

main().catch((err) => {
  console.error(`Error: ${err instanceof Error ? err.message : String(err)}`);
  process.exitCode = 1;
});
