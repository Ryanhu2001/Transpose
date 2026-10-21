import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { test } from 'node:test';
import { buildManifest, validateReleaseUrl, validateSignature, validateVersion } from './update-manifest.mjs';

const scratch = resolve('.build');
mkdirSync(scratch, { recursive: true });
const version = '0.6.0';
const baseUrl = 'https://github.com/Ryanhu2001/Transpose/releases/download/v0.6.0/';

function fixture(run) {
  const root = mkdtempSync(resolve(scratch, 'updater-manifest-'));
  try {
    const cli = resolve('node_modules/@tauri-apps/cli/tauri.js');
    const key = resolve(root, 'fixture.key');
    // Output is captured because `signer generate` prints its private key.
    execFileSync(process.execPath, [cli, 'signer', 'generate', '--ci', '--password', '', '--write-keys', key], { stdio: 'pipe' });
    const publicKey = readFileSync(`${key}.pub`, 'utf8').trim();
    mkdirSync(resolve(root, 'src-tauri'));
    writeFileSync(resolve(root, 'VERSION'), `${version}\n`);
    writeFileSync(resolve(root, 'package.json'), JSON.stringify({ version }));
    writeFileSync(resolve(root, 'src-tauri/tauri.conf.json'), JSON.stringify({ version, plugins: { updater: { pubkey: publicKey, requireSignedVersion: true } } }));
    const contents = resolve(root, 'Transpose.app/Contents');
    mkdirSync(contents, { recursive: true });
    writeFileSync(resolve(contents, 'Info.plist'), `<plist><dict><key>CFBundleShortVersionString</key><string>${version}</string></dict></plist>`);
    const macos = resolve(root, `Transpose-${version}-macOS-arm64.app.tar.gz`);
    execFileSync('tar', ['-czf', macos, '-C', root, 'Transpose.app']);
    const windows = resolve(root, `Transpose-${version}-Windows-x64-setup.exe`);
    writeFileSync(windows, Buffer.from('MZ test installer'));
    const windowsMetadata = resolve(root, 'windows.json');
    writeFileSync(windowsMetadata, JSON.stringify({ version, productVersion: `${version}.0`, architecture: 'x64', sha256: createHash('sha256').update(readFileSync(windows)).digest('hex') }));
    for (const artifact of [macos, windows]) {
      execFileSync(process.execPath, [cli, 'signer', 'sign', '--private-key-path', key, '--password', '', '--app-version', version, artifact], { stdio: 'pipe' });
    }
    return run({ version, tag: `v${version}`, baseUrl, macos, windows, windowsMetadata, root, publicKey, key, cli });
  } finally { rmSync(root, { recursive: true, force: true }); }
}

test('manifest accepts real Tauri signatures and includes exactly both supported platforms', () => fixture((input) => {
  const manifest = buildManifest(input);
  assert.equal(manifest.version, version);
  assert.deepEqual(Object.keys(manifest.platforms), ['darwin-aarch64', 'windows-x86_64']);
  assert.equal(manifest.platforms['darwin-aarch64'].url, `${baseUrl}Transpose-${version}-macOS-arm64.app.tar.gz`);
  assert.equal(manifest.platforms['windows-x86_64'].signature, readFileSync(`${input.windows}.sig`, 'utf8').trim());
}));

test('manifest rejects partial platforms and mismatched project versions', () => fixture((input) => {
  assert.throws(() => buildManifest({ ...input, windows: undefined }), /Both macOS/);
  writeFileSync(resolve(input.root, 'package.json'), JSON.stringify({ version: '0.7.0' }));
  assert.throws(() => buildManifest(input), /configuration versions differ/);
}));

test('version and asset URL validation reject ambiguous versions and insecure destinations', () => {
  for (const value of ['v0.6.0', '01.6.0', '0.6', '0.6.0-01', '0.6.0/evil', '0.6.0\n']) assert.throws(() => validateVersion(value));
  for (const value of ['0.6.0', '1.0.0-beta.1', '1.0.0+build.2']) assert.equal(validateVersion(value), value);
  for (const url of [baseUrl.replace('https:', 'http:'), `${baseUrl}?token=test`, baseUrl.replace('v0.6.0', 'v0.5.0'), baseUrl.replace('github.com', 'example.com'), baseUrl.replace('github.com', 'user:pass@github.com')]) assert.throws(() => validateReleaseUrl(url, 'v0.6.0'));
});

test('signature validator rejects malformed encodings, wrong keys and unversioned signatures', () => fixture((input) => {
  const signature = readFileSync(`${input.macos}.sig`, 'utf8').trim();
  const payload = readFileSync(input.macos);
  for (const invalid of ['', 'abcd!', `${signature}=`, Buffer.from('not a signature').toString('base64')]) assert.throws(() => validateSignature(invalid, input.publicKey, version, payload));
  assert.throws(() => validateSignature(signature, input.publicKey, '0.7.0', payload), /Signature version differs/);
  const keyLines = Buffer.from(input.publicKey, 'base64').toString().trim().split('\n');
  const keyPayload = Buffer.from(keyLines[1], 'base64');
  keyPayload[2] ^= 1;
  const differentKey = Buffer.from(`${keyLines[0]}\n${keyPayload.toString('base64')}\n`).toString('base64');
  assert.throws(() => validateSignature(signature, differentKey, version, payload), /different updater key/);
  execFileSync(process.execPath, [input.cli, 'signer', 'sign', '--private-key-path', input.key, '--password', '', input.windows], { stdio: 'pipe' });
  assert.throws(() => validateSignature(readFileSync(`${input.windows}.sig`, 'utf8'), input.publicKey, version, readFileSync(input.windows)), /Signature version differs/);
}));

test('signature verification rejects altered artifact, forged version, substituted key and global signature', () => fixture((input) => {
  const signature = readFileSync(`${input.macos}.sig`, 'utf8').trim();
  const payload = readFileSync(input.macos);
  const altered = Buffer.from(payload);
  altered[0] ^= 1;
  assert.throws(() => validateSignature(signature, input.publicKey, version, altered), /Artifact signature verification failed/);
  const lines = Buffer.from(signature, 'base64').toString('utf8').trimEnd().split(/\r?\n/);
  lines[2] = lines[2].replace(`version:${version}`, 'version:0.7.0');
  const forgedVersion = Buffer.from(lines.join('\n')).toString('base64');
  assert.throws(() => validateSignature(forgedVersion, input.publicKey, '0.7.0', payload), /trusted comment verification failed/);
  lines[3] = Buffer.alloc(64).toString('base64');
  const forgedGlobal = Buffer.from(lines.join('\n')).toString('base64');
  assert.throws(() => validateSignature(forgedGlobal, input.publicKey, version, payload), /trusted comment verification failed/);
  const keyLines = Buffer.from(input.publicKey, 'base64').toString('utf8').trimEnd().split(/\r?\n/);
  const key = Buffer.from(keyLines[1], 'base64');
  key[10] ^= 1;
  keyLines[1] = key.toString('base64');
  const forgedKey = Buffer.from(keyLines.join('\n')).toString('base64');
  assert.throws(() => validateSignature(signature, forgedKey, version, payload), /Artifact signature verification failed/);
}));

test('macOS archive and Windows inspected metadata must match VERSION', () => fixture((input) => {
  writeFileSync(input.windowsMetadata, JSON.stringify({ version, productVersion: '0.5.0', architecture: 'x64' }));
  assert.throws(() => buildManifest(input), /Windows installer metadata differs/);
  writeFileSync(input.windowsMetadata, JSON.stringify({ version, productVersion: version, architecture: 'x64', sha256: '0'.repeat(64) }));
  assert.throws(() => buildManifest(input), /does not match its inspected metadata/);
  writeFileSync(resolve(input.root, 'Transpose.app/Contents/Info.plist'), '<plist><dict><key>CFBundleShortVersionString</key><string>0.5.0</string></dict></plist>');
  execFileSync('tar', ['-czf', input.macos, '-C', input.root, 'Transpose.app']);
  assert.throws(() => buildManifest(input), /macOS bundle version differs/);
}));
