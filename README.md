# CLIProxyAPI Updater

This repository contains two release-based updater scripts for [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI):

* `update_cliproxyapi.ps1` for PowerShell
* `update_cliproxyapi.py` for Python

Both scripts fetch the matching GitHub release asset for the current OS/architecture, compare it with the locally installed version, and install or upgrade the package in place.

## What the scripts actually do

* Query the latest release, or a specific tag such as `v6.8.35`
* Detect the local installed version by running `cli-proxy-api --help`
* Match the right release asset for `windows`, `linux`, or `darwin` and `amd64`/`arm64`
* Validate the asset exists in the release
* Download and extract the package
* Replace the installation directory with the new release contents
* Rename `config.example.yaml` to `config.yaml` during a full install
* Back up an existing `config.yaml` to a timestamped file in the temp directory before replacement
* Verify the installed version matches the requested release
* Support optional GitHub token authentication

## Supported options

### PowerShell

```powershell
./update_cliproxyapi.ps1
./update_cliproxyapi.ps1 -CheckOnly
./update_cliproxyapi.ps1 -DryRun
./update_cliproxyapi.ps1 -TargetVersion v6.8.35
./update_cliproxyapi.ps1 -Force
./update_cliproxyapi.ps1 -AllowDowngrade
./update_cliproxyapi.ps1 -KeepTemp
./update_cliproxyapi.ps1 -GitHubToken "github_pat_xxx"
./update_cliproxyapi.ps1 -InstallDir "C:\Tools\CLIProxyAPI"
```

Token priority:

1. `-GitHubToken`
2. `$env:GITHUB_TOKEN`
3. `$env:GH_TOKEN`

### Python

```bash
python update_cliproxyapi.py
python update_cliproxyapi.py --check-only
python update_cliproxyapi.py --dry-run
python update_cliproxyapi.py --target-version v6.8.35
python update_cliproxyapi.py --force
python update_cliproxyapi.py --allow-downgrade
python update_cliproxyapi.py --keep-temp
python update_cliproxyapi.py --update-exe-only
python update_cliproxyapi.py --github-token github_pat_xxx
python update_cliproxyapi.py --install-dir /opt/CLIProxyAPI
```

Token priority:

1. `--github-token`
2. `GITHUB_TOKEN`
3. `GH_TOKEN`

## Running with uv

The Python script can also be run with [`uv`](https://github.com/astral-sh/uv).

This is useful if you want a simple way to pass environment variables from a `.env` file without manually exporting them first.

For example:

```bash
uv run --env-file .env update_cliproxyapi.py
```

Example `.env`:

```env
GITHUB_TOKEN=github_pat_xxx
```

You can still pass normal script arguments:

```bash
uv run --env-file .env update_cliproxyapi.py --check-only
uv run --env-file .env update_cliproxyapi.py --target-version v6.8.35
uv run --env-file .env update_cliproxyapi.py --install-dir /opt/CLIProxyAPI
```

Using `uv` is optional. The Python script can still be run directly with Python.

## Behavior notes

* `--check-only` / `-CheckOnly` only reports local and target version information; no install happens.
* `--dry-run` / `-DryRun` prints the planned action summary without modifying files.
* A matching version exits successfully unless `--force` / `-Force` is set.
* A newer local version exits unless `--allow-downgrade` / `-AllowDowngrade` is set.
* The Python script includes an additional `--update-exe-only` mode that replaces just the binary and leaves the rest of the install directory untouched.
* The PowerShell script performs a full replacement of the install directory and does not have a binary-only mode.

## Inspiration

This project takes inspiration from:

* [CLIProxyAPI-mate](https://github.com/hexbee/CLIProxyAPI-mate)
* [cliproxyapi-installer](https://github.com/brokechubb/cliproxyapi-installer)

Both projects provided useful ideas around simplifying CLIProxyAPI installation, updates, and maintenance.

This repository keeps a narrower scope: small standalone PowerShell and Python scripts focused specifically on release-based updates.

## Notes

* This repo does not provide a broader CLI management interface; it is a small GitHub-release updater for the upstream CLIProxyAPI project.
* `uv` is optional and is mainly useful for convenient Python execution and `.env` loading.
* The implementation is the source of truth for supported arguments and workflows.
