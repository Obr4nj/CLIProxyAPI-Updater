# CLIProxyAPI Updater

A lightweight Windows updater and management toolkit for [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI).

This project provides simple PowerShell and Python utilities to keep CLIProxyAPI up to date with the latest GitHub release.

The main goal is to make CLIProxyAPI maintenance on Windows simple and predictable without requiring users to manually check releases, download archives, replace binaries, or manage Python environments.

## Features

* Check the latest CLIProxyAPI release from GitHub
* Compare the latest release with the locally installed version
* Automatically download the appropriate Windows release
* Update the CLIProxyAPI executable while preserving existing configuration
* Stop and restart CLIProxyAPI during updates when needed
* Skip updates when the installed version is already current
* PowerShell-based Windows automation
* Python utilities managed with [`uv`](https://github.com/astral-sh/uv)
* Designed to stay lightweight, transparent, and easy to modify

## Goals

This project focuses on a few simple principles:

* **Windows-first** — built specifically around PowerShell and common Windows workflows
* **Minimal setup** — avoid unnecessary services or complex installation steps
* **Safe updates** — preserve configuration and user data whenever possible
* **Simple tooling** — small scripts that are easy to understand and customize
* **Low maintenance** — reduce the manual work required to keep CLIProxyAPI current

## Scope

This repository is not intended to replace CLIProxyAPI itself or provide a full management interface.

Its purpose is primarily to provide lightweight tooling around:

* Release checking
* Version comparison
* Binary updates
* Process management
* Update automation
* Supporting utilities

CLIProxyAPI configuration, authentication, providers, and API functionality remain the responsibility of the upstream project.

## Tech Stack

The project primarily uses:

* **PowerShell** for Windows automation and process management
* **Python** for supporting utilities and logic
* **uv** for Python dependency and environment management
* **GitHub Releases API** for retrieving upstream release information

## Upstream

This project is built around:

[router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)

CLIProxyAPI binaries, releases, and core functionality are maintained by the upstream project.

This repository only provides additional update and management tooling.

## Inspiration

This project takes inspiration from:

* [CLIProxyAPI-mate](https://github.com/hexbee/CLIProxyAPI-mate)
* [cliproxyapi-installer](https://github.com/brokechubb/cliproxyapi-installer)

The goal is to provide a smaller, Windows-focused approach using PowerShell and Python.

## Disclaimer

This is an independent community project and is not officially affiliated with or endorsed by CLIProxyAPI or its maintainers.
