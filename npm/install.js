// postinstall: fetch the 3code release binary for this platform.
'use strict';

const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const version = require('./package.json').version;
const binDir = path.join(__dirname, 'bin');

function assetFor(platform, arch) {
  // Termux reports Linux but runs bionic; it needs the Termux build, which
  // links Termux OpenSSL. $PREFIX with a lib dir is the same signal the
  // shell installer uses.
  if (platform === 'linux' && process.env.PREFIX &&
      fs.existsSync(path.join(process.env.PREFIX, 'lib'))) {
    if (arch === 'arm64') return '3code-termux-arm64.tar.gz';
    throw new Error(`unsupported Termux architecture: ${arch} (only arm64 builds are provided)`);
  }
  if (platform === 'linux') {
    if (arch === 'x64') return '3code-linux-amd64.tar.gz';
    if (arch === 'arm64') return '3code-linux-arm64.tar.gz';
  } else if (platform === 'darwin') {
    return '3code-macos-universal.tar.gz';
  } else if (platform === 'win32') {
    if (arch === 'x64') return '3code-windows-amd64.zip';
  }
  throw new Error(`unsupported platform: ${platform}-${arch} (build from source: https://github.com/capocasa/3code)`);
}

async function main() {
  const asset = assetFor(process.platform, process.arch);
  const url = `https://github.com/capocasa/3code/releases/download/${version}/${asset}`;
  const archive = path.join(binDir, asset);
  console.log(`3code: downloading ${asset}`);

  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`download failed: ${res.status} ${res.statusText} for ${url}`);
  }
  fs.mkdirSync(binDir, { recursive: true });
  fs.writeFileSync(archive, Buffer.from(await res.arrayBuffer()));

  // Archives are flat: members sit at the archive root, no wrapper dir.
  // tar -xf reads the zip too on Windows, where tar is bsdtar.
  execFileSync('tar', ['-xf', archive, '-C', binDir], { stdio: 'inherit' });
  fs.unlinkSync(archive);
  if (process.platform !== 'win32') {
    fs.chmodSync(path.join(binDir, '3code'), 0o755);
  }
  console.log('3code: installed');
}

main().catch((err) => {
  console.error('3code postinstall failed:', err.message);
  console.error('alternatives: the install script at https://3code.capocasa.dev, or npm rebuild 3code');
  process.exit(1);
});
