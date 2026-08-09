#!/usr/bin/env python3
"""
CLIProxyAPI updater (Python)

Port of:
https://github.com/hexbee/CLIProxyAPI-mate/blob/master/update_cliproxyapi.sh

Token priority:
  1. --github-token
  2. GITHUB_TOKEN
  3. GH_TOKEN

Examples:
  python update_cliproxyapi.py
  python update_cliproxyapi.py --check-only
  python update_cliproxyapi.py --dry-run
  python update_cliproxyapi.py --target-version v6.8.35
  python update_cliproxyapi.py --update-exe-only
  python update_cliproxyapi.py --github-token github_pat_xxx
  GITHUB_TOKEN=github_pat_xxx python update_cliproxyapi.py
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import platform
import re
import shutil
import ssl
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path
from typing import Any, Optional


GITHUB_REPO = "router-for-me/CLIProxyAPI"
GITHUB_API_BASE = f"https://api.github.com/repos/{GITHUB_REPO}"
USER_AGENT = "CLIProxyAPI-Python-Updater"
API_VERSION = "2022-11-28"


class Color:
    GREEN = "\033[0;32m"
    YELLOW = "\033[1;33m"
    RED = "\033[0;31m"
    RESET = "\033[0m"


def enable_windows_ansi() -> None:
    if os.name == "nt":
        os.system("")


def info(msg: str) -> None:
    print(f"{Color.YELLOW}{msg}{Color.RESET}")


def success(msg: str) -> None:
    print(f"{Color.GREEN}{msg}{Color.RESET}")


def error(msg: str) -> None:
    print(f"{Color.RED}Error: {msg}{Color.RESET}", file=sys.stderr)


def fail(msg: str, code: int = 1) -> "NoReturn":
    error(msg)
    raise SystemExit(code)


def normalize_version(value: str) -> str:
    value = value.strip()
    if value.lower().startswith("v"):
        value = value[1:]
    if value.lower().endswith("-plus"):
        value = value[:-5]
    return value


def version_parts(value: str) -> tuple[int, ...]:
    nums = re.findall(r"\d+", normalize_version(value))
    return tuple(int(x) for x in nums)


def compare_versions(left: str, right: str) -> int:
    """
    Return:
      -1 if left < right
       0 if left == right
       1 if left > right

    This mirrors the source script's numeric version intent closely enough for
    CLIProxyAPI release tags such as 6.8.35.
    """
    a_norm = normalize_version(left)
    b_norm = normalize_version(right)

    if a_norm == b_norm:
        return 0

    a = list(version_parts(a_norm))
    b = list(version_parts(b_norm))
    max_len = max(len(a), len(b))

    a.extend([0] * (max_len - len(a)))
    b.extend([0] * (max_len - len(b)))

    if a < b:
        return -1
    if a > b:
        return 1

    # Fallback when numeric components are equal but suffixes differ.
    a_lower = a_norm.lower()
    b_lower = b_norm.lower()
    return -1 if a_lower < b_lower else 1


def resolve_token(cli_token: Optional[str]) -> Optional[str]:
    if cli_token and cli_token.strip():
        return cli_token.strip()

    for name in ("GITHUB_TOKEN", "GH_TOKEN"):
        value = os.environ.get(name)
        if value and value.strip():
            return value.strip()

    return None


def github_headers(token: Optional[str], binary: bool = False) -> dict[str, str]:
    headers = {
        "Accept": "application/octet-stream" if binary else "application/vnd.github+json",
        "X-GitHub-Api-Version": API_VERSION,
        "User-Agent": USER_AGENT,
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def request(
    url: str,
    token: Optional[str],
    *,
    binary: bool = False,
    timeout: int = 60,
) -> urllib.response.addinfourl:
    req = urllib.request.Request(
        url,
        headers=github_headers(token, binary=binary),
        method="GET",
    )

    try:
        return urllib.request.urlopen(req, timeout=timeout)
    except urllib.error.HTTPError as exc:
        body = ""
        try:
            body = exc.read().decode("utf-8", errors="replace").strip()
        except Exception:
            pass

        detail = f"HTTP {exc.code} {exc.reason}"
        if body:
            # Avoid printing huge GitHub responses.
            detail += f": {body[:800]}"
        raise RuntimeError(f"GitHub request failed: {url}\n{detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"GitHub request failed: {url}\n{exc.reason}") from exc


def print_rate_limit(headers: Any) -> None:
    limit = headers.get("X-RateLimit-Limit")
    remaining = headers.get("X-RateLimit-Remaining")
    reset = headers.get("X-RateLimit-Reset")

    if not (limit and remaining and reset):
        return

    reset_display = str(reset)
    try:
        ts = int(reset)
        reset_display = dt.datetime.fromtimestamp(ts).strftime("%I:%M:%S %p")
    except Exception:
        pass

    print(f"GitHub API: {remaining} / {limit} remaining | reset {reset_display}")


def fetch_release(
    target_version: Optional[str],
    token: Optional[str],
) -> dict[str, Any]:
    if target_version:
        tag = f"v{normalize_version(target_version)}"
        url = f"{GITHUB_API_BASE}/releases/tags/{tag}"
        info(f"Fetching release metadata for {tag} from GitHub...")
    else:
        tag = None
        url = f"{GITHUB_API_BASE}/releases/latest"
        info("Fetching latest release metadata from GitHub...")

    try:
        with request(url, token) as resp:
            print_rate_limit(resp.headers)
            raw = resp.read()
    except RuntimeError as exc:
        if tag:
            fail(f"failed to fetch release metadata for {tag}.\n{exc}")
        fail(f"failed to fetch the latest release metadata.\n{exc}")

    try:
        release = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"failed to parse GitHub release JSON: {exc}")

    release_tag = str(release.get("tag_name") or "").strip()
    if not release_tag:
        fail("failed to parse tag_name from GitHub API response.")

    if target_version:
        print(f"Target release: {release_tag}")
    else:
        print(f"Latest release: {release_tag}")

    print("JSON parser: Python json")
    print(f"GitHub authentication: {'token enabled' if token else 'anonymous'}")
    return release


def map_arch(machine: str) -> str:
    machine = machine.lower()
    if machine in ("x86_64", "amd64", "x64"):
        return "amd64"
    if machine in ("aarch64", "arm64"):
        return "arm64"
    fail(f"unsupported architecture: {machine}")


def detect_platform(version: str) -> dict[str, str]:
    system = platform.system().lower()
    arch = map_arch(platform.machine())

    if system == "windows":
        platform_name = "windows"
        archive_ext = "zip"
        binary_name = "cli-proxy-api.exe"
    elif system == "linux":
        platform_name = "linux"
        archive_ext = "tar.gz"
        binary_name = "cli-proxy-api"
    elif system == "darwin":
        platform_name = "darwin"
        archive_ext = "tar.gz"
        binary_name = "cli-proxy-api"
    else:
        fail(f"unsupported platform: {platform.system()}")

    package_name = f"CLIProxyAPI_{version}_{platform_name}_{arch}.{archive_ext}"

    return {
        "platform": platform_name,
        "arch": arch,
        "archive_ext": archive_ext,
        "binary_name": binary_name,
        "package_name": package_name,
        "platform_label": f"{platform_name}/{arch}",
    }


def find_asset(release: dict[str, Any], package_name: str) -> Optional[dict[str, Any]]:
    assets = release.get("assets") or []
    for asset in assets:
        if str(asset.get("name") or "") == package_name:
            return asset
    return None


def validate_asset(release: dict[str, Any], package_name: str) -> dict[str, Any]:
    asset = find_asset(release, package_name)
    if asset:
        return asset

    error(f"expected asset not found for this platform: {package_name}")
    print("Available assets:")
    for item in release.get("assets") or []:
        name = str(item.get("name") or "").strip()
        if name:
            print(f"  - {name}")
    raise SystemExit(1)


def detect_local_version(install_dir: Path, binary_name: str) -> Optional[str]:
    binary = install_dir / binary_name

    if not binary.is_file():
        print("Local version: not installed")
        return None

    try:
        proc = subprocess.run(
            [str(binary), "--help"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            check=False,
            timeout=30,
        )
    except Exception as exc:
        fail(f"failed to execute '{binary} --help' to detect the local version: {exc}")

    if proc.returncode != 0:
        fail(f"failed to execute '{binary} --help' to detect the local version.")

    match = re.search(
        r"^CLIProxyAPI Version:\s*([^,\s]+)",
        proc.stdout,
        flags=re.MULTILINE,
    )
    if not match:
        fail(f"failed to parse the local version from '{binary} --help'.")

    raw = match.group(1)
    normalized = normalize_version(raw)
    print(f"Local version: {raw}")
    return normalized


def show_plan(
    *,
    platform_label: str,
    install_dir: Path,
    release_tag: str,
    package_name: str,
    download_url: str,
    keep_temp: bool,
    token: Optional[str],
    local_version: Optional[str],
    target_version: str,
    force: bool,
    allow_downgrade: bool,
    update_exe_only: bool,
) -> None:
    print("Planned action summary:")
    print(f"  Platform: {platform_label}")
    print(f"  Install directory: {install_dir}")
    print(f"  Target release: {release_tag}")
    print(f"  Target package: {package_name}")
    print(f"  Download URL: {download_url}")
    print("  JSON parser: Python json")
    print(f"  Keep temp files: {1 if keep_temp else 0}")
    print(f"  GitHub auth: {'token' if token else 'anonymous'}")
    print(f"  Install mode: {'binary only' if update_exe_only else 'full package'}")

    if not local_version:
        print("  Local status: not installed")
        print("  Decision: fresh install")
        return

    print(f"  Local normalized version: {local_version}")
    cmp_result = compare_versions(local_version, target_version)

    if cmp_result == 0:
        if force:
            print("  Decision: reinstall same version due to --force")
        else:
            print("  Decision: already up to date, would exit")
    elif cmp_result > 0:
        if allow_downgrade:
            print("  Decision: downgrade install allowed by --allow-downgrade")
        else:
            print("  Decision: downgrade detected, would exit")
    else:
        print("  Decision: update to newer version")


def download_asset(
    asset: dict[str, Any],
    destination: Path,
    token: Optional[str],
) -> None:
    """
    With a token, use the GitHub asset API URL + Accept: application/octet-stream.
    Without a token, use browser_download_url for public releases.
    """
    if token and asset.get("url"):
        url = str(asset["url"])
        binary_api = True
    else:
        url = str(asset.get("browser_download_url") or "")
        binary_api = False

    if not url:
        fail("release asset has no usable download URL.")

    try:
        with request(url, token, binary=binary_api, timeout=180) as resp:
            with destination.open("wb") as fh:
                shutil.copyfileobj(resp, fh, length=1024 * 1024)
    except RuntimeError as exc:
        fail(f"failed to download release asset.\n{exc}")


def safe_extract_tar(archive: Path, destination: Path) -> None:
    """
    Extract tar while rejecting path traversal.
    Compatible with Python versions where tarfile.extractall(filter=...) may not exist.
    """
    destination_resolved = destination.resolve()

    with tarfile.open(archive, "r:gz") as tf:
        for member in tf.getmembers():
            member_target = (destination / member.name).resolve()
            try:
                member_target.relative_to(destination_resolved)
            except ValueError:
                fail(f"unsafe path in archive: {member.name}")

        try:
            tf.extractall(destination, filter="data")
        except TypeError:
            tf.extractall(destination)


def safe_extract_zip(archive: Path, destination: Path) -> None:
    destination_resolved = destination.resolve()

    with zipfile.ZipFile(archive, "r") as zf:
        for member in zf.infolist():
            member_target = (destination / member.filename).resolve()
            try:
                member_target.relative_to(destination_resolved)
            except ValueError:
                fail(f"unsafe path in archive: {member.filename}")

        zf.extractall(destination)


def extract_archive(archive: Path, destination: Path, platform_name: str) -> None:
    destination.mkdir(parents=True, exist_ok=True)

    try:
        if platform_name == "windows":
            safe_extract_zip(archive, destination)
        else:
            safe_extract_tar(archive, destination)
    except (zipfile.BadZipFile, tarfile.TarError, OSError) as exc:
        fail(f"failed to extract package: {exc}")


def resolve_package_root(extract_dir: Path) -> Path:
    entries = list(extract_dir.iterdir())
    if len(entries) == 1 and entries[0].is_dir():
        return entries[0]
    return extract_dir


def backup_existing_config(install_dir: Path, temp_dir: Path) -> Optional[str]:
    config = install_dir / "config.yaml"
    if not config.is_file():
        return None

    timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_name = f"config.{timestamp}.yaml"
    shutil.copy2(config, temp_dir / backup_name)
    info(f"Backed up existing config.yaml to {backup_name}.")
    return backup_name


def copy_directory_contents(source: Path, destination: Path) -> None:
    for child in source.iterdir():
        target = destination / child.name
        if child.is_dir():
            shutil.copytree(child, target, symlinks=True)
        else:
            shutil.copy2(child, target, follow_symlinks=False)


def install_release(
    package_root: Path,
    install_dir: Path,
    temp_dir: Path,
    backup_name: Optional[str],
    binary_name: str,
) -> None:
    if install_dir.exists():
        shutil.rmtree(install_dir)

    install_dir.mkdir(parents=True, exist_ok=True)
    copy_directory_contents(package_root, install_dir)

    example_config = install_dir / "config.example.yaml"
    if not example_config.is_file():
        fail("config.example.yaml not found in the extracted package.")

    config = install_dir / "config.yaml"
    if config.exists():
        config.unlink()
    example_config.replace(config)

    if backup_name:
        shutil.copy2(temp_dir / backup_name, install_dir / backup_name)

    binary = install_dir / binary_name
    if not binary.is_file():
        fail(f"expected binary '{binary_name}' not found after installation.")

    # Ensure executable bit on Unix-like systems.
    if os.name != "nt":
        mode = binary.stat().st_mode
        binary.chmod(mode | 0o111)



def install_binary_only(
    package_root: Path,
    install_dir: Path,
    binary_name: str,
) -> None:
    """
    Replace only cli-proxy-api(.exe).

    Existing config.yaml, backups, logs, certificates, and all other files in
    install_dir are left untouched.
    """
    source_binary = package_root / binary_name

    if not source_binary.is_file():
        # Be slightly more tolerant in case a release wraps files in an extra
        # directory structure.
        matches = list(package_root.rglob(binary_name))
        if len(matches) == 1:
            source_binary = matches[0]
        elif len(matches) > 1:
            fail(
                f"multiple '{binary_name}' files were found in the extracted "
                "package; refusing to guess which one to install."
            )
        else:
            fail(f"expected binary '{binary_name}' not found in the extracted package.")

    install_dir.mkdir(parents=True, exist_ok=True)
    destination = install_dir / binary_name

    # Copy to a temporary sibling first, then replace the destination. This
    # avoids leaving a partially-written executable if the copy fails.
    staged = install_dir / f".{binary_name}.update-tmp"

    try:
        if staged.exists():
            staged.unlink()

        shutil.copy2(source_binary, staged)

        if os.name != "nt":
            mode = staged.stat().st_mode
            staged.chmod(mode | 0o111)

        # On Windows this will fail cleanly if cli-proxy-api.exe is still
        # running/locked, rather than deleting unrelated installation files.
        os.replace(staged, destination)
    except PermissionError as exc:
        fail(
            f"cannot replace '{destination}'. Stop CLIProxyAPI if it is running "
            f"and try again: {exc}"
        )
    except OSError as exc:
        fail(f"failed to replace '{destination}': {exc}")
    finally:
        try:
            if staged.exists():
                staged.unlink()
        except OSError:
            pass


def parse_args() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    env_install_dir = os.environ.get("INSTALL_DIR")
    default_install_dir = (
        Path(env_install_dir).expanduser()
        if env_install_dir
        else script_dir / "CLIProxyAPI"
    )

    parser = argparse.ArgumentParser(
        description="Install/update CLIProxyAPI from GitHub releases."
    )
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Only print local and target version information.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned actions without making changes.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Reinstall even when local version matches target.",
    )
    parser.add_argument(
        "--allow-downgrade",
        action="store_true",
        help="Allow installing an older target version.",
    )
    parser.add_argument(
        "--keep-temp",
        action="store_true",
        help="Keep downloaded archive and extracted temporary files.",
    )
    parser.add_argument(
        "--update-exe-only",
        action="store_true",
        help=(
            "Replace only cli-proxy-api(.exe); keep config.yaml and all other "
            "installation files untouched."
        ),
    )
    parser.add_argument(
        "--target-version",
        metavar="TAG",
        help="Install a specific release tag, e.g. v6.8.35.",
    )
    parser.add_argument(
        "--github-token",
        metavar="TOKEN",
        help="GitHub token. Prefer GITHUB_TOKEN env var to avoid shell history.",
    )
    parser.add_argument(
        "--install-dir",
        type=Path,
        default=default_install_dir,
        help=f"Installation directory (default: {default_install_dir}).",
    )
    return parser.parse_args()


def main() -> int:
    enable_windows_ansi()
    args = parse_args()

    token = resolve_token(args.github_token)
    install_dir = args.install_dir.expanduser().resolve()

    temp_dir = Path(tempfile.mkdtemp(prefix="cliproxyapi-update-"))
    extract_dir = temp_dir / "extracted"

    try:
        release = fetch_release(args.target_version, token)

        release_tag = str(release["tag_name"])
        version = normalize_version(release_tag)

        detected = detect_platform(version)
        platform_name = detected["platform"]
        archive_ext = detected["archive_ext"]
        binary_name = detected["binary_name"]
        package_name = detected["package_name"]
        platform_label = detected["platform_label"]

        asset = validate_asset(release, package_name)

        browser_download_url = str(
            asset.get("browser_download_url")
            or f"https://github.com/{GITHUB_REPO}/releases/download/{release_tag}/{package_name}"
        )

        local_version = detect_local_version(install_dir, binary_name)

        if args.check_only:
            success("Check completed. No changes made.")
            return 0

        if args.dry_run:
            show_plan(
                platform_label=platform_label,
                install_dir=install_dir,
                release_tag=release_tag,
                package_name=package_name,
                download_url=browser_download_url,
                keep_temp=args.keep_temp,
                token=token,
                local_version=local_version,
                target_version=version,
                force=args.force,
                allow_downgrade=args.allow_downgrade,
                update_exe_only=args.update_exe_only,
            )
            success("Dry run completed. No changes made.")
            return 0

        if local_version:
            cmp_result = compare_versions(local_version, version)

            if cmp_result == 0 and not args.force:
                success("CLIProxyAPI is already up to date. Exiting.")
                return 0

            if cmp_result == 0 and args.force:
                info("Local version matches target version, continuing due to --force.")

            if cmp_result > 0:
                if not args.allow_downgrade:
                    fail(
                        f"local version ({local_version}) is newer than target version "
                        f"({version}). Re-run with --allow-downgrade to continue."
                    )
                info("Downgrade allowed by --allow-downgrade.")

        archive_path = temp_dir / f"package.{archive_ext}"

        info(f"Target platform: {platform_label}")
        info(f"Install directory: {install_dir}")
        info(f"Downloading {package_name}...")
        download_asset(asset, archive_path, token)

        info("Extracting package...")
        extract_archive(archive_path, extract_dir, platform_name)
        package_root = resolve_package_root(extract_dir)

        backup_name = None

        if args.update_exe_only:
            info("Updating binary only; existing config and other files will be preserved...")
            install_binary_only(
                package_root=package_root,
                install_dir=install_dir,
                binary_name=binary_name,
            )
        else:
            backup_name = backup_existing_config(install_dir, temp_dir)

            info("Replacing installation directory...")
            install_release(
                package_root=package_root,
                install_dir=install_dir,
                temp_dir=temp_dir,
                backup_name=backup_name,
                binary_name=binary_name,
            )

        installed_version = detect_local_version(install_dir, binary_name)
        if not installed_version:
            fail("failed to verify the installed version after installation.")

        if installed_version != version:
            fail(
                f"installed version mismatch. Expected {version}, "
                f"got {installed_version}."
            )

        success(f"Verified installed version: {installed_version}")
        success(f"CLIProxyAPI {version} installed successfully.")
        print(f"Binary: {install_dir / binary_name}")
        print(f"Config: {install_dir / 'config.yaml'}")

        if backup_name:
            print(f"Backup: {install_dir / backup_name}")

        return 0

    finally:
        if args.keep_temp:
            info(f"Keeping temporary files at {temp_dir}")
        else:
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
