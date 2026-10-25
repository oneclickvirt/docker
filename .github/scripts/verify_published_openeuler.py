#!/usr/bin/env python3
"""Verify the published archive, then boot and restart it on a native runner."""
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import urllib.request


def run(arguments, **kwargs):
    environment = dict(os.environ)
    environment.pop('GH_TOKEN', None)
    environment.pop('GITHUB_TOKEN', None)
    return subprocess.run(arguments, env=environment, check=True,
                          timeout=kwargs.pop('timeout', 120), **kwargs)


def main():
    target, arch = os.environ['IMAGE_TARGET'], os.environ['IMAGE_ARCH']
    if target not in ('docker', 'containerd', 'podman') or arch not in ('amd64', 'arm64'):
        raise ValueError('Unexpected image selector')
    if os.uname().machine != {'amd64': 'x86_64', 'arm64': 'aarch64'}[arch]:
        raise RuntimeError('Native image architecture is required')
    name = f'spiritlhl_openeuler_{arch}.tar.gz'
    headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'oneclickvirt-image-verification'}
    token = os.environ.get('GH_TOKEN')
    if token:
        headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(
        f'https://api.github.com/repos/oneclickvirt/{target}/releases/tags/openeuler', headers=headers)
    with urllib.request.urlopen(request, timeout=60) as response:
        release = json.load(response)
    assets = [asset for asset in release['assets'] if asset['name'] == name]
    if len(assets) != 1 or assets[0]['state'] != 'uploaded':
        raise RuntimeError('Published image archive is unavailable')
    asset = assets[0]
    if not asset.get('digest', '').startswith('sha256:'):
        raise RuntimeError('Published image has no SHA256 digest')
    with tempfile.TemporaryDirectory(prefix='published-openeuler-', dir=os.environ['RUNNER_TEMP']) as temporary:
        folder = Path(temporary)
        archive = folder / name
        # Release downloads are public; never forward the API credential.
        run(['curl', '--fail', '--location', '--silent', '--show-error', '--retry', '3',
             '--connect-timeout', '15', '--max-time', '900', '-o', str(archive),
             asset['browser_download_url']], timeout=1200)
        with archive.open('rb') as stream:
            digest = 'sha256:' + hashlib.file_digest(stream, 'sha256').hexdigest()
        if archive.stat().st_size != asset['size'] or digest != asset['digest']:
            raise RuntimeError('Published image archive checksum or size mismatch')
        transport = 'oci-archive' if target == 'podman' else 'docker-archive'
        source = transport + ':' + str(archive)
        config = json.loads(run(['skopeo', 'inspect', '--config', source],
                                capture_output=True, text=True).stdout)
        if config['architecture'] != arch or config['os'] != 'linux':
            raise RuntimeError('Image configuration has the wrong architecture or OS')
        image = 'oneclickvirt-published-test:' + secrets.token_hex(8)
        container = 'published-euler-' + secrets.token_hex(8)
        password = secrets.token_urlsafe(32)
        envfile = folder / 'container.env'
        envfile.touch(mode=0o600)
        envfile.write_text('ROOT_PASSWORD=' + password + '\n')
        sshenv = dict(os.environ, SSHPASS=password)
        sshenv.pop('GH_TOKEN', None)
        sshenv.pop('GITHUB_TOKEN', None)
        marker = secrets.token_hex(16)
        try:
            run(['sudo', 'skopeo', 'copy', source, 'docker-daemon:' + image], timeout=600)
            run(['docker', 'run', '--detach', '--name', container, '--env-file', str(envfile),
                 '--publish', '127.0.0.1::22', image], capture_output=True)
            address = run(['docker', 'port', container, '22/tcp'], capture_output=True, text=True).stdout.strip()
            port = address.rsplit(':', 1)[1]
            ssh = ['sshpass', '-e', 'ssh', '-p', port, '-o', 'StrictHostKeyChecking=no',
                   '-o', 'UserKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=5',
                   '-o', 'ConnectionAttempts=1', '-o', 'LogLevel=ERROR', 'root@127.0.0.1']
            def ready():
                deadline = time.monotonic() + 180
                while time.monotonic() < deadline:
                    if run(['docker', 'inspect', '--format', '{{.State.Running}}', container],
                           capture_output=True, text=True).stdout.strip() != 'true':
                        raise RuntimeError('Published container stopped before SSH readiness')
                    result = subprocess.run(ssh + ['true'], env=sshenv, capture_output=True, timeout=15)
                    if result.returncode == 0:
                        return
                    time.sleep(3)
                raise RuntimeError('Published container SSH readiness timed out')
            def check():
                command = ('set -eu; . /etc/os-release; '
                           'test "$(printf %s "$ID" | tr "[:upper:]" "[:lower:]")" = openeuler; '
                           'sshd -t; '
                           'curl -fsSL --connect-timeout 10 --max-time 30 https://github.com -o /dev/null')
                subprocess.run(ssh + [command], env=sshenv, capture_output=True, timeout=60, check=True)
            ready()
            check()
            subprocess.run(ssh + ['printf %s ' + marker + ' > /tmp/published-image-restart'],
                           env=sshenv, capture_output=True, timeout=30, check=True)
            started = run(['docker', 'inspect', '--format', '{{.State.StartedAt}}', container],
                          capture_output=True, text=True).stdout
            run(['docker', 'restart', container], capture_output=True)
            ready()
            check()
            restarted = run(['docker', 'inspect', '--format', '{{.State.StartedAt}}', container],
                            capture_output=True, text=True).stdout
            result = subprocess.run(ssh + ['cat /tmp/published-image-restart'], env=sshenv,
                                    capture_output=True, text=True, timeout=30, check=True)
            if started == restarted or result.stdout != marker:
                raise RuntimeError('Container restart or filesystem persistence failed')
            print(f'PUBLISHED_IMAGE_VERIFIED repository=oneclickvirt/{target} asset={name} '
                  f'id={asset["id"]} size={asset["size"]} {digest} '
                  f'arch={arch} SSH=true HTTPS=true restart=true', flush=True)
        finally:
            subprocess.run(['docker', 'rm', '--force', container], capture_output=True, timeout=30)
            subprocess.run(['docker', 'image', 'rm', image], capture_output=True, timeout=30)


if __name__ == '__main__':
    main()
