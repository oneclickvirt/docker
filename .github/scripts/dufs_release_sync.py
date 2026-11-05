#!/usr/bin/env python3
"""Copy image Release assets to the public Dufs mirror.

The GitHub Release remains the source of truth.  This helper only publishes a
verified copy after a release is already available, so a mirror outage cannot
fail the original release.  It also runs in CNB pipelines with
``--all-releases``.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import time
from http.client import HTTPSConnection, HTTPConnection
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen


IMAGE_SUFFIXES = (".qcow2", ".raw", ".img", ".iso", ".iso.7z", ".7z",
                  ".zip", ".tar.xz", ".tar.zst", ".tar.gz")
SYSTEMS = ("rockylinux", "almalinux", "openwrt", "openeuler", "opensuse",
           "archlinux", "debian", "ubuntu", "alpine", "centos", "oracle",
           "fedora", "gentoo", "kali", "void", "freebsd", "devuan", "windows", "macos")


def api_json(url: str, token: str | None) -> object:
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "oneclickvirt-dufs-sync"}
    if token:
        headers["Authorization"] = "Bearer " + token
    for attempt in range(3):
        try:
            with urlopen(Request(url, headers=headers), timeout=60) as response:
                return json.loads(response.read())
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)
    raise AssertionError("unreachable")


def release_list(repository: str, tag: str | None, token: str | None) -> list[dict]:
    if tag:
        payload = api_json(
            "https://api.github.com/repos/" + repository + "/releases/tags/" + quote(tag, safe=""),
            token,
        )
        return [payload] if isinstance(payload, dict) and payload.get("assets") is not None else []
    releases: list[dict] = []
    for page in range(1, 101):
        payload = api_json(
            f"https://api.github.com/repos/{repository}/releases?per_page=100&page={page}", token
        )
        if not isinstance(payload, list) or not payload:
            break
        releases.extend(item for item in payload if isinstance(item, dict) and not item.get("draft"))
        if len(payload) < 100:
            break
    return releases


def system_name(asset: str) -> str:
    lower = asset.lower().replace("-", "_")
    return next((name for name in SYSTEMS if name in lower), "misc")


def arch_name(asset: str) -> str:
    lower = asset.lower()
    if "arm64" in lower or "aarch64" in lower:
        return "arm64"
    if "armv7" in lower or "armhf" in lower or "arm_" in lower:
        return "arm"
    return "amd64"


def mirror_path(repository: str, tag: str, asset: str) -> str:
    repo = repository.rsplit("/", 1)[-1]
    if repo in ("pve_kvm_images", "kvm_images"):
        root = "pve/kvm"
    elif repo in ("pve_lxc_images", "lxc_amd64_images", "lxc_arm_images"):
        root = "pve/lxc"
    elif repo in ("incus_images", "lxd_images"):
        kind = "kvm" if "kvm" in tag.lower() or "_kvm" in asset.lower() else "lxc"
        root = repo.removesuffix("_images") + "/" + kind
    elif repo in ("docker", "containerd", "podman"):
        root = "runtime/" + repo
    else:
        raise ValueError(f"unsupported image repository: {repo}")
    return f"{root}/{system_name(asset)}/{arch_name(asset)}/{asset}"


def image_asset(asset: dict) -> bool:
    name = str(asset.get("name", ""))
    return (bool(name) and name not in (".", "..") and "/" not in name and "\\" not in name
            and not any(ord(c) < 32 for c in name) and name.lower().endswith(IMAGE_SUFFIXES))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url: str, destination: Path, token: str | None) -> str:
    headers = {"Accept": "application/octet-stream", "User-Agent": "oneclickvirt-dufs-sync"}
    # Release assets are public; never forward an API token to a CDN redirect.
    for attempt in range(3):
        try:
            with urlopen(Request(url, headers=headers), timeout=120) as response, destination.open("wb") as output:
                digest = hashlib.sha256()
                while True:
                    block = response.read(8 * 1024 * 1024)
                    if not block:
                        break
                    output.write(block)
                    digest.update(block)
                output.flush()
            return digest.hexdigest()
        except Exception:
            destination.unlink(missing_ok=True)
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)
    raise AssertionError("unreachable")


def publish(endpoint: str, user: str, password: str, path: Path, rel: str,
            source: str, tag: str, published_at: str = "") -> dict:
    parsed = urlparse(endpoint)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError("DUFS_PUBLISH_URL must be an http(s) URL")
    request_path = parsed.path or "/__mirror/publish"
    if request_path.endswith("/"):
        request_path = request_path[:-1]
    if parsed.query:
        request_path += "?" + parsed.query
    connection_class = HTTPSConnection if parsed.scheme == "https" else HTTPConnection
    size = path.stat().st_size
    auth = base64.b64encode(f"{user}:{password}".encode()).decode("ascii")
    headers = {
        "Authorization": "Basic " + auth,
        "Content-Length": str(size),
        "Content-Type": "application/octet-stream",
        "X-Mirror-Path": quote(rel, safe="/"),
        "X-Mirror-SHA256": sha256(path),
        "X-Mirror-Source": quote(source, safe=""),
        "X-Mirror-Release": quote(tag, safe=""),
        "X-Mirror-Published-At": published_at,
    }
    for attempt in range(3):
        connection = connection_class(parsed.hostname, parsed.port, timeout=180)
        try:
            connection.putrequest("POST", request_path)
            for key, value in headers.items():
                connection.putheader(key, value)
            connection.endheaders()
            with path.open("rb") as source_file:
                for block in iter(lambda: source_file.read(8 * 1024 * 1024), b""):
                    connection.send(block)
            response = connection.getresponse()
            body = response.read(4096).decode("utf-8", "replace")
            if 200 <= response.status < 300:
                try:
                    return json.loads(body)
                except json.JSONDecodeError:
                    return {"status": response.status, "body": body}
            raise RuntimeError(f"Dufs publish HTTP {response.status}: {body[:500]}")
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)
        finally:
            connection.close()
    raise AssertionError("unreachable")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--tag", default=os.environ.get("DUFS_RELEASE_TAG", ""))
    parser.add_argument("--all-releases", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--asset", default="", help="Mirror one exact image asset")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        raise SystemExit("repository must look like owner/name")
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    endpoint = os.environ.get("DUFS_PUBLISH_URL", "")
    user = os.environ.get("DUFS_PUBLISH_USER", "")
    password = os.environ.get("DUFS_PUBLISH_PASSWORD", "")
    if not args.dry_run and (not endpoint or not user or not password):
        raise SystemExit("DUFS_PUBLISH_URL, DUFS_PUBLISH_USER and DUFS_PUBLISH_PASSWORD are required")
    releases = release_list(args.repository, None if args.all_releases else (args.tag or None), token)
    catalog = {"entries": {}, "sources": {}}
    if not args.dry_run:
        parsed = urlparse(endpoint)
        catalog_url = f"{parsed.scheme}://{parsed.netloc}/catalog.json"
        # Fail early on an unavailable mirror instead of downloading hundreds
        # of gigabytes that cannot be published. API credentials stay on GitHub.
        with urlopen(catalog_url, timeout=30) as response:
            catalog = json.loads(response.read())
    count = 0
    releases.sort(key=lambda r: r.get("published_at") or r.get("created_at") or "")
    for release in releases:
        tag = str(release.get("tag_name", ""))
        for asset in release.get("assets", []):
            if not isinstance(asset, dict) or not image_asset(asset):
                continue
            name = str(asset["name"])
            if args.asset and args.asset != name:
                continue
            rel = mirror_path(args.repository, tag, name)
            source = str(asset.get("browser_download_url", ""))
            if not source:
                continue
            expected = str(asset.get("digest") or "").removeprefix("sha256:")
            published_at = asset.get("updated_at") or release.get("published_at") or ""
            prior = catalog.get("sources", {}).get(source, {})
            indexed = catalog.get("entries", {}).get(prior.get("path"), {})
            if prior and indexed.get("size") == asset.get("size") and (
                (expected and prior.get("sha256") == expected) or
                (not expected and indexed.get("published_at") == published_at)
            ):
                continue
            count += 1
            print(f"mirror {args.repository} {tag} {name} -> {rel}", flush=True)
            if args.dry_run:
                continue
            with tempfile.TemporaryDirectory(prefix="dufs-release-") as directory:
                local = Path(directory) / name
                digest = download(source, local, token)
                if local.stat().st_size != int(asset.get("size", -1)):
                    raise RuntimeError(f"Size mismatch for {source}")
                if expected and digest.lower() != expected.lower():
                    raise RuntimeError(f"SHA256 mismatch for {source}: expected {expected}, got {digest}")
                result = publish(endpoint, user, password, local, rel, source, tag, published_at)
                print(f"published {rel} sha256={digest} result={result.get('status')}", flush=True)
    print(f"dufs mirror assets={count}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
