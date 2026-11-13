"""Publish a draft first; make it public only after every asset is uploaded.

Uses the scoped GitHub Actions token. Never prints it; no external dependencies.
"""
import argparse
import json
import os
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request

REPO = 'k0x7q/ai-gateway-setup'
API = 'https://api.github.com/repos/' + REPO


def request(url, token, method='GET', data=None, content_type='application/json'):
    headers = {'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
               'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'ai-gateway-setup-release'}
    if data is not None:
        headers['Content-Type'] = content_type
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers,
                                                      method=method), timeout=180) as response:
        return json.load(response)


def publish(version, directory):
    token = os.environ['GITHUB_TOKEN']
    manifest = json.loads((directory / 'manifest.json').read_text())
    if manifest['version'] != version or manifest['repository'] != REPO:
        raise ValueError('Release metadata mismatch')
    import hashlib
    files = sorted(manifest['sha256']) + ['manifest.json', 'SHA256SUMS']
    for name in files:
        p = directory / name
        if p.is_symlink() or not p.is_file() or p.name != name:
            raise ValueError('Unsafe or missing asset')
        if name in manifest['sha256'] and hashlib.sha256(p.read_bytes()).hexdigest() != manifest['sha256'][name]:
            raise ValueError('Asset checksum mismatch')
    # Never overwrite an already published (or failed draft) release silently.
    try:
        request(API + '/releases/tags/' + urllib.parse.quote(version, safe=''), token)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    else:
        raise ValueError('Release already exists; inspect/delete a failed draft or publish a new version')
    body = {'tag_name': version, 'name': version, 'draft': True, 'prerelease': False,
            'body': '一条命令安装／配置 Claude Code 或配置 Codex。使用命令见仓库 README。\n'
                    '辅助脚本经过 SHA-256 校验；下载内容放入临时目录，流程结束自动清理。\n'
                    'Codex 客户端不由本工具安装。'}
    release = request(API + '/releases', token, 'POST', json.dumps(body).encode())
    upload = release['upload_url'].split('{', 1)[0]
    parsed_upload = urllib.parse.urlsplit(upload)
    if parsed_upload.scheme != 'https' or parsed_upload.netloc != 'uploads.github.com':
        raise ValueError('Unexpected upload endpoint; refusing to send token')
    for name in files:
        result = request(upload + '?name=' + urllib.parse.quote(name, safe=''), token, 'POST',
                         (directory / name).read_bytes(), 'application/octet-stream')
        if result.get('state') != 'uploaded' or result.get('size') != (directory / name).stat().st_size:
            raise ValueError('Asset upload was not confirmed')
        print('Uploaded', name)
    published = request(API + '/releases/' + str(release['id']), token, 'PATCH',
                        json.dumps({'draft': False, 'make_latest': 'true'}).encode())
    print('Published', published['html_url'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--version', required=True)
    parser.add_argument('--directory', type=Path, default=Path('dist'))
    args = parser.parse_args()
    publish(args.version, args.directory)
