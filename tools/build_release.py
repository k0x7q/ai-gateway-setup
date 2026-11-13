"""Build byte-preserving, checksummed release assets without running installers."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
# Explicit allowlist: never publish personal configs, backups, tests or old ZIPs.
ASSETS = {
    'claude-mac-setup.rb': 'claude-gateway-setup/mac/辅助文件/setup.rb',
    'claude-mac-configure.cjs': 'claude-gateway-setup/common/configure.cjs',
    'claude-mac-dialogs.cjs': 'claude-gateway-setup/common/dialogs.cjs',
    'claude-windows-Setup.ps1': 'claude-gateway-setup/windows/辅助文件/Setup.ps1',
    'claude-windows-configure.cjs': 'claude-gateway-setup/common/configure.cjs',
    'claude-windows-dialogs.cjs': 'claude-gateway-setup/common/dialogs.cjs',
    'claude-windows-key-dialog.ps1': 'claude-gateway-setup/common/key-dialog.ps1',
    'codex-mac-codex_setup.rb': 'codex-gateway-setup/mac/辅助文件/codex_setup.rb',
    'codex-windows-Setup.ps1': 'codex-gateway-setup/windows/辅助文件/Setup.ps1',
    'codex-windows-ConfigCore.ps1': 'codex-gateway-setup/windows/辅助文件/ConfigCore.ps1',
}


def assert_regular(path):
    for ancestor in (path, *path.parents):
        if ancestor.is_symlink():
            raise ValueError('Refuse linked path: ' + str(ancestor))
    if not path.is_file():
        raise ValueError('Missing source: ' + str(path))


def write_output(path, data):
    for ancestor in (path, *path.parents):
        if ancestor.is_symlink():
            raise ValueError('Refuse linked output: ' + str(ancestor))
    if path.exists() and not path.is_file():
        raise ValueError('Output is not a regular file')
    path.write_bytes(data)


def build(version, output=None):
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Version must be vMAJOR.MINOR.PATCH')
    out = Path(output) if output else ROOT / 'dist'
    if out.is_symlink():
        raise ValueError('Refuse linked output directory')
    out.mkdir(parents=True, exist_ok=True)
    hashes = {}
    for name, relative in ASSETS.items():
        source = ROOT / relative
        assert_regular(source)
        data = source.read_bytes()
        if name.endswith('.ps1') and not data.startswith(b'\xef\xbb\xbf'):
            raise ValueError(name + ': Windows PowerShell Chinese text requires UTF-8 BOM')
        hashes[name] = hashlib.sha256(data).hexdigest()
        write_output(out / name, data)
    for template, target in (('setup-mac.sh.in', 'setup-mac.sh'),
                             ('setup-windows.ps1.in', 'setup-windows.ps1')):
        source = ROOT / 'bootstrap' / template
        assert_regular(source)
        text = source.read_text(encoding='utf-8-sig')
        platform = 'mac' if target.endswith('.sh') else 'windows'
        selected = {name: value for name, value in hashes.items() if '-' + platform + '-' in name}
        if platform == 'mac':
            entries = '\n'.join('        ' + name + ') expected="' + digest + '" ;;'
                                for name, digest in sorted(selected.items()))
        else:
            entries = '\n'.join("    '" + name + "' = '" + digest + "'"
                                for name, digest in sorted(selected.items()))
        if text.count('@@VERSION@@') != 1 or text.count('@@HASHES@@') != 1:
            raise ValueError('Unexpected template placeholders: ' + template)
        text = text.replace('@@VERSION@@', version).replace('@@HASHES@@', entries)
        if '@@' in text:
            raise ValueError('Unexpanded placeholder')
        data = (text.replace('\r\n', '\n').replace('\n', '\r\n').encode('utf-8-sig')
                if platform == 'windows' else text.encode('utf-8'))
        write_output(out / target, data)
        hashes[target] = hashlib.sha256(data).hexdigest()
    manifest = {'version': version, 'repository': 'k0x7q/ai-gateway-setup', 'sha256': hashes}
    write_output(out / 'manifest.json', (json.dumps(manifest, indent=2) + '\n').encode('utf-8'))
    write_output(out / 'SHA256SUMS', ''.join(digest + '  ' + name + '\n'
                                          for name, digest in sorted(hashes.items())).encode('ascii'))
    print('Built', len(hashes), 'checked assets for', version)
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--version', default=(ROOT / 'VERSION').read_text().strip())
    parser.add_argument('--output')
    args = parser.parse_args()
    build(args.version, args.output)
