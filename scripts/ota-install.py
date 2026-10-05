#!/usr/bin/env python3
"""Temporarily serve a verified IPA over tailnet HTTPS on an unused Serve port."""
import argparse
import functools
import html
import http.server
import json
import os
import plistlib
import signal
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path


def command(*args):
    result = subprocess.run(args, capture_output=True, check=False)
    if result.returncode:
        raise RuntimeError('Tailscale command failed; check that Tailscale is running')
    return json.loads(result.stdout)


def occupied_ports(config):
    ports = set()
    if not isinstance(config, dict):
        return ports
    for key, value in config.items():
        if key == 'TCP':
            ports.update(int(port) for port in value)
        elif key in ('Web', 'AllowFunnel'):
            ports.update(int(host.rsplit(':', 1)[1]) for host in value)
        elif isinstance(value, dict):
            ports.update(occupied_ports(value))
    return ports


def choose_port(config, requested):
    occupied = occupied_ports(config)
    candidates = [int(requested)] if requested else [8443, 10000, *range(10001, 10101)]
    for port in candidates:
        if not 1 <= port <= 65535:
            raise ValueError('OTA_HTTPS_PORT must be a valid TCP port')
        if port not in occupied:
            return port
    raise ValueError('Requested HTTPS port is occupied, or no free OTA port is available')


def write_page(root, base, info):
    title = info.get('CFBundleDisplayName') or info.get('CFBundleName') or 'App'
    manifest = {'items': [{'assets': [{'kind': 'software-package', 'url': base + '/app.ipa'}],
                          'metadata': {'bundle-identifier': info['CFBundleIdentifier'],
                                       'bundle-version': info['CFBundleVersion'],
                                       'kind': 'software', 'title': title}}]}
    (root / 'manifest.plist').write_bytes(plistlib.dumps(manifest))
    install = 'itms-services://?action=download-manifest&url=' + urllib.parse.quote(base + '/manifest.plist', safe='')
    (root / 'index.html').write_text(
        '<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">'
        f'<title>Install {html.escape(title)}</title>'
        '<body style="font:20px -apple-system;padding:48px 24px;text-align:center">'
        f'<h2>{html.escape(title)} {html.escape(str(info.get("CFBundleShortVersionString", "")))}</h2>'
        f'<p><a href="{html.escape(install, quote=True)}">Install</a></p></body>')


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()


def serve(ipa):
    ttl = int(os.environ.get('OTA_TTL', '900'))
    if ttl <= 0:
        raise ValueError('OTA_TTL must be positive')
    status = command('tailscale', 'status', '--json')
    host = status['Self']['DNSName'].rstrip('.')
    if not host:
        raise ValueError('Tailscale HTTPS DNS name is unavailable')
    port = choose_port(command('tailscale', 'serve', 'status', '--json'), os.environ.get('OTA_HTTPS_PORT'))
    base = f'https://{host}' + (f':{port}' if port != 443 else '')
    with tempfile.TemporaryDirectory(prefix='cochlea-ota-') as temporary:
        root = Path(temporary)
        with zipfile.ZipFile(ipa) as archive:
            infos = [name for name in archive.namelist()
                     if name.startswith('Payload/') and name.endswith('.app/Info.plist') and name.count('/') == 2]
            if len(infos) != 1:
                raise ValueError('Expected one app Info.plist in the IPA')
            info = plistlib.loads(archive.read(infos[0]))
        # A private temporary link avoids a second plaintext IPA copy.
        (root / 'app.ipa').symlink_to(ipa.resolve())
        write_page(root, base, info)
        with http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(root))) as server:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            process = None
            try:
                # Check again immediately before starting. Never use --yes, --bg, reset or off.
                choose_port(command('tailscale', 'serve', 'status', '--json'), str(port))
                process = subprocess.Popen(
                    ['tailscale', 'serve', '--bg=false', f'--https={port}', f'http://127.0.0.1:{server.server_port}'],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                expected = (root / 'manifest.plist').read_bytes()
                for _ in range(30):
                    if process.poll() is not None:
                        raise RuntimeError('Tailscale Serve exited before the page was ready')
                    try:
                        with urllib.request.urlopen(base + '/manifest.plist', timeout=2) as response:
                            if response.read() == expected:
                                break
                    except (urllib.error.URLError, TimeoutError):
                        pass
                    time.sleep(1)
                else:
                    raise RuntimeError('OTA HTTPS page did not become ready')
                print(f'Install page: {base}/', flush=True)
                print(f'Open in Safari on the tailnet-connected phone. Serving for {ttl}s; Ctrl-C stops it.', flush=True)
                deadline = time.monotonic() + ttl
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError('Tailscale Serve stopped unexpectedly')
                    time.sleep(min(1, max(0, deadline - time.monotonic())))
            finally:
                if process is not None and process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                server.shutdown()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(143)))
    try:
        serve(args.ipa)
    except KeyboardInterrupt:
        pass
    except (ValueError, RuntimeError, OSError, KeyError, zipfile.BadZipFile):
        raise SystemExit('OTA failed; check the verified IPA, Tailscale HTTPS, and port availability.') from None


if __name__ == '__main__':
    main()
