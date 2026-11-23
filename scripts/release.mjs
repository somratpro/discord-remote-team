import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const plist = fileURLToPath(new URL('../Info.plist', import.meta.url));
const component = process.argv[2];

function run(command, args) {
  return execFileSync(command, args, { cwd: root, encoding: 'utf8' }).trim();
}

function git(...args) {
  return run('git', args);
}

function publish(tag) {
  git('push', '--atomic', 'origin', 'HEAD:refs/heads/main', `refs/tags/${tag}`);
  console.log(`Pushed ${tag}. GitHub Actions will publish the universal DMG.`);
}

function release() {
  if (!['patch', 'minor', 'major'].includes(component)) {
    throw new Error('Choose patch, minor, or major.');
  }
  if (git('branch', '--show-current') !== 'main' || git('status', '--porcelain')) {
    throw new Error('Release from main with a clean working tree so only committed changes are published.');
  }

  git('fetch', 'origin', 'main', '--tags');
  const head = git('rev-parse', 'HEAD');
  const remote = git('rev-parse', 'FETCH_HEAD');
  if (git('merge-base', remote, head) !== remote) {
    throw new Error('Local main is behind or has diverged from origin/main. Sync it before publishing.');
  }

  const current = run('plutil', ['-extract', 'CFBundleShortVersionString', 'raw', plist]);
  const build = run('plutil', ['-extract', 'CFBundleVersion', 'raw', plist]);
  if (!/^\d+\.\d+\.\d+$/.test(current) || !/^\d+$/.test(build)) {
    throw new Error('Info.plist must contain a semantic version and a numeric build number.');
  }

  // A failed atomic push leaves the release commit and tag locally. Retry that release.
  const currentTag = `v${current}`;
  if (head !== remote && git('tag', '--points-at', head).split('\n').includes(currentTag)) {
    console.log(`Retrying the pending ${currentTag} release.`);
    publish(currentTag);
    return;
  }

  const version = current.split('.').map(Number);
  const index = ['major', 'minor', 'patch'].indexOf(component);
  version[index] += 1;
  version.fill(0, index + 1);
  const next = version.join('.');
  const tag = `v${next}`;
  if (git('tag', '--list', tag)) {
    throw new Error(`Tag ${tag} already exists. No files were changed.`);
  }

  const original = readFileSync(plist);
  try {
    run('plutil', ['-replace', 'CFBundleShortVersionString', '-string', next, plist]);
    run('plutil', ['-replace', 'CFBundleVersion', '-string', String(Number(build) + 1), plist]);
    git('commit', '-m', `Release ${tag}`, '--', 'Info.plist');
  } catch (error) {
    writeFileSync(plist, original);
    throw error;
  }

  git('tag', tag);
  publish(tag);
}

try {
  release();
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
