"""Build clean Claude Code distributions from explicitly selected source files.

Shared JavaScript/GUI helpers in common are authoritative. No tests, documentation,
macOS xattrs, or executable installer code are run while building these ZIPs.
"""
from pathlib import Path
import io
import os
import stat
import zipfile

ROOT = Path(__file__).resolve().parent
PLANS = (
    ('Mac', 'mac', '双击此文件安装配置 Claude Code.command', ('setup.rb', 'configure.cjs', 'dialogs.cjs')),
    ('Windows', 'windows', '双击此文件安装配置 Claude Code.cmd', ('Setup.ps1', 'configure.cjs', 'dialogs.cjs', 'key-dialog.ps1')),
)


def build_packages():
    for platform, directory, launcher, helpers in PLANS:
        source = ROOT / directory
        auxiliary = source / '辅助文件'
        if source.is_symlink() or auxiliary.is_symlink():
            raise RuntimeError('Refuse linked source/helper directories')
        auxiliary.mkdir(exist_ok=True)
        for name in helpers:
            if name in ('setup.rb', 'Setup.ps1'):
                continue
            shared = ROOT / 'common' / name
            destination = auxiliary / name
            if shared.is_symlink() or destination.is_symlink():
                raise RuntimeError('Refuse linked helper source/destination')
            destination.write_bytes(shared.read_bytes())
            destination.chmod(0o644)
        startup = source / launcher
        if startup.is_symlink():
            raise RuntimeError('Refuse linked launcher')
        if platform == 'Mac':
            startup.chmod(0o755)
        prefix = 'ClaudeCode网关配置-' + platform
        expected = {prefix + '/' + launcher: startup}
        expected.update({prefix + '/辅助文件/' + name: auxiliary / name for name in helpers})
        for path in expected.values():
            if path.is_symlink() or not path.is_file():
                raise RuntimeError('Missing or linked source: ' + str(path))
        if platform == 'Windows':
            for name in ('Setup.ps1', 'key-dialog.ps1'):
                contents = (auxiliary / name).read_bytes()
                assert contents.startswith(b'\xef\xbb\xbf'), name + ' requires UTF-8 BOM'
                assert b'\n' not in contents.replace(b'\r\n', b''), name + ' requires CRLF'
            batch = startup.read_bytes()
            assert not batch.startswith(b'\xef\xbb\xbf')
            assert batch.startswith(b'@echo off\r\nchcp 65001 >nul\r\n')
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.write(startup, prefix + '/' + launcher)
            archive.write(auxiliary, prefix + '/辅助文件/')
            for name in helpers:
                archive.write(auxiliary / name, prefix + '/辅助文件/' + name)
        with zipfile.ZipFile(buffer) as archive:
            assert archive.testzip() is None
            assert set(archive.namelist()) == set(expected) | {prefix + '/辅助文件/'}
            for name, source_file in expected.items():
                assert archive.read(name) == source_file.read_bytes()
            if platform == 'Mac':
                assert stat.S_IMODE(archive.getinfo(prefix + '/' + launcher).external_attr >> 16) == 0o755
            assert {name[len(prefix) + 1:].split('/')[0] for name in archive.namelist()} == {launcher, '辅助文件'}
        output = ROOT / (prefix + '.zip')
        if output.is_symlink():
            raise RuntimeError('Refuse linked ZIP destination')
        output.write_bytes(buffer.getvalue())
        print('PASS:', output.name)
        for name in expected:
            print(' ', name)
    print('PASS: only launcher + helper folder shipped; source bytes and executable/encoding metadata verified.')


if __name__ == '__main__':
    build_packages()
