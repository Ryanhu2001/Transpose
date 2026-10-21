#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { createHash, createPublicKey, verify } from 'node:crypto';
import { readFileSync, statSync, writeFileSync } from 'node:fs';
import { basename, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const semver = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*)?$/;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

export function validateVersion(version) {
  assert(typeof version === 'string' && semver.test(version), 'Use a valid SemVer version without a v prefix.');
  return version;
}

function decodeBase64(value, label) {
  assert(typeof value === 'string' && value.length > 0 && value.length < 32_768, `${label} is missing or too large.`);
  assert(/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value), `${label} is not canonical base64.`);
  const decoded = Buffer.from(value, 'base64');
  assert(decoded.toString('base64') === value, `${label} is not canonical base64.`);
  return decoded;
}

// Match minisign-verify's Ed/ED envelope using Node's standard Ed25519 and
// BLAKE2b primitives. Both the artifact and trusted comment must verify.
export function validateSignature(value, publicKey, version, payload) {
  const keyLines = decodeBase64(publicKey, 'Updater public key').toString('utf8').trimEnd().split(/\r?\n/);
  assert(keyLines.length === 2 && keyLines[0].startsWith('untrusted comment: '), 'Invalid updater public key envelope.');
  const key = decodeBase64(keyLines[1], 'Updater public key payload');
  assert(key.length === 42 && key.subarray(0, 2).toString() === 'Ed', 'Invalid updater public key payload.');
  const signature = value.trim();
  const lines = decodeBase64(signature, 'Updater signature').toString('utf8').trimEnd().split(/\r?\n/);
  assert(lines.length === 4 && lines[0].startsWith('untrusted comment: ') && lines[2].startsWith('trusted comment: '), 'Invalid Tauri signature envelope.');
  const signed = decodeBase64(lines[1], 'Updater signature payload');
  const global = decodeBase64(lines[3], 'Updater comment signature');
  assert(signed.length === 74 && ['Ed', 'ED'].includes(signed.subarray(0, 2).toString()) && global.length === 64, 'Invalid Tauri signature payload.');
  assert(signed.subarray(2, 10).equals(key.subarray(2, 10)), 'Artifact was signed with a different updater key.');
  assert(Buffer.isBuffer(payload) && payload.length > 0, 'Artifact bytes are required for signature verification.');
  const ed25519 = createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), key.subarray(10)]), format: 'der', type: 'spki' });
  const message = signed.subarray(0, 2).toString() === 'ED' ? createHash('blake2b512').update(payload).digest() : payload;
  const signatureBytes = signed.subarray(10);
  assert(verify(null, message, ed25519, signatureBytes), 'Artifact signature verification failed.');
  const trustedComment = lines[2].slice('trusted comment: '.length);
  assert(verify(null, Buffer.concat([signatureBytes, Buffer.from(trustedComment)]), ed25519, global), 'Signature trusted comment verification failed.');
  const versions = trustedComment.split('\t').filter((field) => field.startsWith('version:'));
  assert(versions.length === 1 && versions[0].slice('version:'.length) === version, 'Signature version differs from VERSION; sign with --app-version.');
  return signature;
}

export function validateReleaseUrl(value, tag) {
  const url = new URL(value);
  assert(url.protocol === 'https:' && !url.username && !url.password && !url.search && !url.hash && !url.port, 'Update assets require an HTTPS URL without credentials, query, fragment or port.');
  const suffix = `/releases/download/${encodeURIComponent(tag)}/`;
  assert(url.hostname === 'github.com' && url.pathname.endsWith(suffix), 'Use the GitHub release download URL for the supplied tag.');
  assert(/^\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/releases\/download\//.test(url.pathname), 'Invalid GitHub repository release URL.');
  return url.href;
}

function assertFile(path, extension) {
  assert(path && basename(path).endsWith(extension), `Expected a ${extension} updater artifact.`);
  const stat = statSync(path);
  assert(stat.isFile() && stat.size > 0, `Empty or missing updater artifact: ${basename(path)}`);
  return path;
}

function archiveVersion(path) {
  const entries = execFileSync('tar', ['-tzf', path], { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 }).split(/\r?\n/);
  const matches = entries.filter((entry) => /^(?:\.\/)?Transpose\.app\/Contents\/Info\.plist$/.test(entry));
  assert(matches.length === 1, 'macOS updater must contain exactly one Transpose.app/Contents/Info.plist.');
  const plist = execFileSync('tar', ['-xOzf', path, matches[0]], { encoding: 'utf8', maxBuffer: 1024 * 1024 });
  const version = plist.match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/)?.[1];
  assert(version, 'macOS updater Info.plist must contain an XML bundle version.');
  return version;
}

export function buildManifest({ version, tag, baseUrl, macos, windows, windowsMetadata, root = projectRoot }) {
  validateVersion(version);
  assert(tag === `v${version}`, 'The existing release tag must be v followed by VERSION.');
  assert(readFileSync(resolve(root, 'VERSION'), 'utf8').trim() === version, 'Requested version differs from VERSION.');
  const config = JSON.parse(readFileSync(resolve(root, 'src-tauri/tauri.conf.json'), 'utf8'));
  const packageJson = JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8'));
  assert(config.version === version && packageJson.version === version, 'App configuration versions differ from VERSION.');
  assert(config.plugins?.updater?.requireSignedVersion === true, 'Updater must require version-bound signatures.');
  const publicKey = config.plugins.updater.pubkey;
  const downloadUrl = validateReleaseUrl(baseUrl, tag);
  assert(macos && windows && windowsMetadata, 'Both macOS arm64 and Windows x64 artifacts and Windows metadata are required.');
  assertFile(macos, '.app.tar.gz');
  assertFile(windows, '-setup.exe');
  assert(archiveVersion(macos) === version, 'macOS bundle version differs from VERSION.');
  const metadata = JSON.parse(readFileSync(windowsMetadata, 'utf8'));
  assert(metadata.version === version && [version, `${version}.0`].includes(metadata.productVersion) && metadata.architecture === 'x64', 'Windows installer metadata differs from VERSION or architecture.');
  const windowsHash = createHash('sha256').update(readFileSync(windows)).digest('hex');
  assert(metadata.sha256 === windowsHash, 'Windows installer does not match its inspected metadata.');
  const platforms = {};
  for (const [platform, path] of [['darwin-aarch64', macos], ['windows-x86_64', windows]]) {
    const signature = validateSignature(readFileSync(`${path}.sig`, 'utf8'), publicKey, version, readFileSync(path));
    platforms[platform] = { signature, url: new URL(encodeURIComponent(basename(path)), downloadUrl).href };
  }
  return { version, platforms };
}

function main(args) {
  const options = {};
  const names = new Set(['version', 'tag', 'base-url', 'macos', 'windows', 'windows-metadata', 'output']);
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index]?.replace(/^--/, '');
    assert(args[index]?.startsWith('--') && names.has(name) && args[index + 1] && !Object.hasOwn(options, name), 'Usage: node scripts/update-manifest.mjs --version VERSION --tag vVERSION --base-url HTTPS_RELEASE_URL/ --macos APP.tar.gz --windows APP-setup.exe --windows-metadata windows.json --output latest.json');
    options[name] = args[index + 1];
  }
  assert(names.size === Object.keys(options).length, 'All manifest arguments are required; both platforms must be present.');
  const manifest = buildManifest({ ...options, baseUrl: options['base-url'], windowsMetadata: options['windows-metadata'] });
  writeFileSync(options.output, `${JSON.stringify(manifest, null, 2)}\n`, { flag: 'wx' });
  console.log(`Prepared ${basename(options.output)} for Transpose ${manifest.version} (macOS arm64, Windows x64).`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error(`Cannot prepare updater manifest: ${error.message}`); process.exitCode = 1; }
}
