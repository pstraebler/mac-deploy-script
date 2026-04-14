# macOS Deploy Script

A Bash script to automate Mac deployment by installing a selected set of applications through a lightweight graphical interface.  
The project supports installation via Homebrew, `.pkg` files, `.dmg` images, and `.mobileconfig` profiles.

## Features

- Checks for and installs required dependencies:
  - Xcode Command Line Tools
  - Git
  - Homebrew
  - `jq`
- Reads an application catalog from a JSON file
- Displays a GUI selection window using `osascript`
- Installs multiple package types:
  - `brew_formula`
  - `brew_cask`
  - `pkg`
  - `dmg_app`
  - `dmg_pkg`
  - `mobileconfig`
- Works locally or through remote execution such as `curl ... | bash`
- Generates an installation log

## How It Works

The script acts as an orchestrator:

1. Checks whether the machine has the required base tools.
2. Loads an `apps.json` file.
3. Optionally creates a local user through the CLI.
4. Grants a Secure Token if the created user is an administrator.
5. Optionally installs Rosetta 2 through the CLI.
6. Displays a selection window.
7. Installs the chosen applications based on their type.
8. Shows a completion message.

## Project Structure

```text
deploy-macos/
├── install-macos-apps.sh
└── apps.json
```


## Requirements

- macOS
- An active user session to display the GUI
- Internet access to download packages and dependencies
- `sudo` privileges for some system-level installations


## Installation

### Option 1 — Local execution

```bash
chmod +x install-macos-apps.sh
./install-macos-apps.sh
```

Verbose mode:

```bash
./install-macos-apps.sh --verbose
```


### Option 2 — Remote execution

```bash
curl -fsSL https://example.com/install-macos-apps.sh | bash
```

Verbose mode:

```bash
curl -fsSL https://example.com/install-macos-apps.sh | bash -s -- --verbose
```


### Option 3 — Remote script with remote JSON catalog

```bash
curl -fsSL https://example.com/install-macos-apps.sh | APP_JSON_URL="https://example.com/apps.json" bash
```


## JSON File Format

The catalog must contain an `apps` key with an array of objects.

Example:

```json
{
  "apps": [
    {
      "name": "Google Chrome",
      "type": "brew_cask",
      "source": "google-chrome"
    },
    {
      "name": "Firefox",
      "type": "brew_cask",
      "source": "firefox"
    },
    {
      "name": "PaperCut",
      "type": "pkg",
      "source": "https://example.com/papercutmac.pkg"
    },
    {
      "name": "Some App",
      "type": "dmg_app",
      "source": "https://example.com/some-app.dmg",
      "app_name": "Some App.app"
    },
    {
      "name": "Some Suite",
      "type": "dmg_pkg",
      "source": "https://example.com/some-suite.dmg",
      "pkg_name": "Installer.pkg"
    },
    {
      "name": "VPN Profile",
      "type": "mobileconfig",
      "source": "https://example.com/vpn.mobileconfig"
    }
  ]
}
```


## Supported Types

### `brew_formula`

Installs a CLI package via Homebrew.

```json
{
  "name": "wget",
  "type": "brew_formula",
  "source": "wget"
}
```


### `brew_cask`

Installs a macOS application via Homebrew Cask.

```json
{
  "name": "Google Chrome",
  "type": "brew_cask",
  "source": "google-chrome"
}
```


### `pkg`

Downloads a `.pkg` file and installs it.

```json
{
  "name": "PaperCut",
  "type": "pkg",
  "source": "https://example.com/papercutmac.pkg"
}
```


### `dmg_app`

Downloads a `.dmg`, mounts it, and copies an app into `/Applications`.

```json
{
  "name": "Some App",
  "type": "dmg_app",
  "source": "https://example.com/some-app.dmg",
  "app_name": "Some App.app"
}
```


### `dmg_pkg`

Downloads a `.dmg`, mounts it, and runs a `.pkg` found inside the mounted volume.

```json
{
  "name": "Some Suite",
  "type": "dmg_pkg",
  "source": "https://example.com/some-suite.dmg",
  "pkg_name": "Installer.pkg"
}
```


### `mobileconfig`

Downloads a profile and opens it for user installation.

```json
{
  "name": "VPN Profile",
  "type": "mobileconfig",
  "source": "https://example.com/vpn.mobileconfig"
}
```


## Environment Variables

The script can be controlled with the following environment variables:


| Variable | Description | Default value |
| :-- | :-- | :-- |
| `APP_JSON_URL` | URL of a remote JSON catalog | empty |
| `APP_JSON_FILE` | Local path to the JSON file | script directory + `/apps.json` |
| `WORKDIR` | Temporary working directory | `/tmp/macos-deploy` |
| `LOG_FILE` | Log file path | `$WORKDIR/install.log` |

Example:

```bash
APP_JSON_FILE="/path/to/apps.json" ./install-macos-apps.sh
```

Or:

```bash
APP_JSON_URL="https://example.com/apps.json" ./install-macos-apps.sh
```

CLI options:

| Option | Description |
| :-- | :-- |
| `-v`, `--verbose` | Enable verbose output |
| `-h`, `--help` | Show help |


## Installation Flow

The script follows this sequence:

- Checks Xcode Command Line Tools
- Checks Git
- Checks Homebrew
- Checks `jq`
- Loads the JSON catalog
- Asks in the CLI whether a local user should be created
- Grants a Secure Token if the created user is an administrator
- Asks in the CLI whether Rosetta 2 should be installed
- Opens a GUI selection window
- Installs each selected application


## Logs

Logs are written to:

```text
/tmp/macos-deploy/install.log
```

This file is useful for diagnosing:

- failed downloads;
- invalid `.pkg` files;
- `.dmg` files that do not contain the expected file name;
- `sudo` permission issues.


## Limitations

- Some `.dmg` installers use non-standard internal layouts.
- `.mobileconfig` profiles may require manual confirmation.
- Xcode Command Line Tools installation may require system interaction.
- The script assumes a graphical user session is available for the GUI selection window.
