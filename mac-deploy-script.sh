#!/usr/bin/env bash
set -Eeuo pipefail

APP_JSON_URL="${APP_JSON_URL:-}"
APP_JSON_FILE="${APP_JSON_FILE:-apps.json}"
WORKDIR="${WORKDIR:-/tmp/macos-deploy}"
LOG_FILE="${LOG_FILE:-$WORKDIR/install.log}"

mkdir -p "$WORKDIR"
touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

CURRENT_MOUNT_POINT=""

cleanup() {
  if [[ -n "${CURRENT_MOUNT_POINT}" && -d "${CURRENT_MOUNT_POINT}" ]]; then
    hdiutil detach "$CURRENT_MOUNT_POINT" -quiet || true
  fi
}
trap cleanup EXIT

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_sudo() {
  if [[ "${EUID}" -ne 0 ]]; then
    sudo -v || fail "Unable to obtain sudo privileges."
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_brew_bin() {
  if [[ -x /opt/homebrew/bin/brew ]]; then
    echo "/opt/homebrew/bin/brew"
  elif [[ -x /usr/local/bin/brew ]]; then
    echo "/usr/local/bin/brew"
  else
    command -v brew || true
  fi
}

ensure_xcode_clt() {
  if xcode-select -p >/dev/null 2>&1; then
    log "Xcode Command Line Tools are already installed."
    return
  fi

  log "Xcode Command Line Tools installation is required."
  xcode-select --install || true

  until xcode-select -p >/dev/null 2>&1; do
    log "Waiting for Xcode Command Line Tools installation to complete..."
    sleep 20
  done

  log "Xcode Command Line Tools installed."
}

ensure_git() {
  if command_exists git; then
    log "Git is already installed."
    return
  fi

  log "Git is missing. Checking again after Xcode Command Line Tools installation..."
  ensure_xcode_clt

  if ! command_exists git; then
    fail "Git is still not available after installing Xcode Command Line Tools."
  fi
}

ensure_homebrew() {
  local brew_bin
  brew_bin="$(detect_brew_bin)"

  if [[ -n "$brew_bin" ]]; then
    log "Homebrew is already installed: $brew_bin"
    return
  fi

  log "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  brew_bin="$(detect_brew_bin)"
  [[ -n "$brew_bin" ]] || fail "Homebrew was installed but the brew command could not be found."

  eval "$("$brew_bin" shellenv)"
  log "Homebrew installed."
}

ensure_brew_shellenv() {
  local brew_bin
  brew_bin="$(detect_brew_bin)"
  [[ -n "$brew_bin" ]] || fail "brew command not found."
  eval "$("$brew_bin" shellenv)"
}

ensure_jq() {
  if command_exists jq; then
    log "jq is already installed."
    return
  fi

  ensure_homebrew
  ensure_brew_shellenv

  log "Installing jq..."
  brew install jq
}

fetch_json_if_needed() {
  if [[ -n "$APP_JSON_URL" ]]; then
    log "Downloading JSON catalog from $APP_JSON_URL"
    curl -fsSL "$APP_JSON_URL" -o "$WORKDIR/apps.json"
    APP_JSON_FILE="$WORKDIR/apps.json"
  fi

  [[ -f "$APP_JSON_FILE" ]] || fail "JSON file not found: $APP_JSON_FILE"
}

validate_json() {
  jq -e '.apps and (.apps | type == "array")' "$APP_JSON_FILE" >/dev/null || fail "Invalid JSON: missing .apps key or .apps is not an array."
}

load_app_names() {
  jq -r '.apps[].name' "$APP_JSON_FILE"
}

get_app_json_by_name() {
  local app_name="$1"
  jq -c --arg name "$app_name" '.apps[] | select(.name == $name)' "$APP_JSON_FILE"
}

show_selection_gui() {
  local items=("$@")
  local joined=""
  local item

  for item in "${items[@]}"; do
    joined="${joined}\"${item}\","
  done
  joined="${joined%,}"

  osascript <<EOF
set appList to {$joined}
set selectedItems to choose from list appList with title "macOS Deployment" with prompt "Select the applications to install:" OK button name "Install" cancel button name "Cancel" with multiple selections allowed
if selectedItems is false then
  return "__CANCELLED__"
else
  set AppleScript's text item delimiters to "|||"
  return selectedItems as text
end if
EOF
}

download_file() {
  local url="$1"
  local output="$2"
  curl -fL --retry 3 --connect-timeout 20 "$url" -o "$output"
}

install_brew_formula() {
  local pkg="$1"

  if brew list "$pkg" >/dev/null 2>&1; then
    log "$pkg is already installed."
    return
  fi

  log "Installing Homebrew formula: $pkg"
  brew install "$pkg"
}

install_brew_cask() {
  local pkg="$1"

  if brew list --cask "$pkg" >/dev/null 2>&1; then
    log "$pkg is already installed."
    return
  fi

  log "Installing Homebrew cask: $pkg"
  brew install --cask "$pkg"
}

install_pkg_file() {
  local pkg_file="$1"
  require_sudo
  log "Installing pkg: $pkg_file"
  sudo installer -pkg "$pkg_file" -target /
}

install_dmg_app() {
  local dmg_file="$1"
  local app_name="$2"
  local mount_point

  mount_point="$(mktemp -d /tmp/macos-dmg.XXXXXX)"
  CURRENT_MOUNT_POINT="$mount_point"

  log "Mounting DMG: $dmg_file"
  hdiutil attach "$dmg_file" -nobrowse -quiet -mountpoint "$mount_point"

  if [[ ! -e "$mount_point/$app_name" ]]; then
    fail "Application not found inside DMG: $app_name"
  fi

  require_sudo
  log "Copying $app_name to /Applications"
  sudo rsync -a "$mount_point/$app_name" /Applications/

  hdiutil detach "$mount_point" -quiet
  CURRENT_MOUNT_POINT=""
}

install_dmg_pkg() {
  local dmg_file="$1"
  local pkg_name="$2"
  local mount_point

  mount_point="$(mktemp -d /tmp/macos-dmg.XXXXXX)"
  CURRENT_MOUNT_POINT="$mount_point"

  log "Mounting DMG: $dmg_file"
  hdiutil attach "$dmg_file" -nobrowse -quiet -mountpoint "$mount_point"

  if [[ ! -e "$mount_point/$pkg_name" ]]; then
    fail "PKG not found inside DMG: $pkg_name"
  fi

  install_pkg_file "$mount_point/$pkg_name"

  hdiutil detach "$mount_point" -quiet
  CURRENT_MOUNT_POINT=""
}

install_mobileconfig() {
  local profile_file="$1"
  log "Opening .mobileconfig profile for user installation."
  open "$profile_file"
}

install_from_entry() {
  local entry="$1"
  local name
  local type
  local source
  local app_name
  local pkg_name
  local tmpfile

  name="$(printf '%s' "$entry" | jq -r '.name')"
  type="$(printf '%s' "$entry" | jq -r '.type')"
  source="$(printf '%s' "$entry" | jq -r '.source')"
  app_name="$(printf '%s' "$entry" | jq -r '.app_name // empty')"
  pkg_name="$(printf '%s' "$entry" | jq -r '.pkg_name // empty')"

  log "=== Processing: $name ($type) ==="

  case "$type" in
    brew_formula)
      install_brew_formula "$source"
      ;;
    brew_cask)
      install_brew_cask "$source"
      ;;
    pkg)
      tmpfile="$WORKDIR/${name// /_}.pkg"
      download_file "$source" "$tmpfile"
      install_pkg_file "$tmpfile"
      ;;
    dmg_app)
      if [[ -z "$app_name" ]]; then
        fail "app_name is required for $name"
      fi
      tmpfile="$WORKDIR/${name// /_}.dmg"
      download_file "$source" "$tmpfile"
      install_dmg_app "$tmpfile" "$app_name"
      ;;
    dmg_pkg)
      if [[ -z "$pkg_name" ]]; then
        fail "pkg_name is required for $name"
      fi
      tmpfile="$WORKDIR/${name// /_}.dmg"
      download_file "$source" "$tmpfile"
      install_dmg_pkg "$tmpfile" "$pkg_name"
      ;;
    mobileconfig)
      tmpfile="$WORKDIR/${name// /_}.mobileconfig"
      download_file "$source" "$tmpfile"
      install_mobileconfig "$tmpfile"
      ;;
    *)
      fail "Unknown type for $name: $type"
      ;;
  esac
}

main() {
  local selected_raw
  local name
  local entry
  local line
  local app_names=()
  local selected_names=()

  log "Starting macOS deployment"

  ensure_xcode_clt
  ensure_git
  ensure_homebrew
  ensure_brew_shellenv
  ensure_jq

  fetch_json_if_needed
  validate_json

  while IFS= read -r line; do
    app_names+=("$line")
  done < <(load_app_names)

  if [[ "${#app_names[@]}" -eq 0 ]]; then
    fail "No applications defined in the JSON catalog."
  fi

  selected_raw="$(show_selection_gui "${app_names[@]}")"

  if [[ "$selected_raw" == "__CANCELLED__" ]]; then
    log "Selection cancelled by the user."
    exit 0
  fi

  IFS='|||' read -r -a selected_names <<< "$selected_raw"

  if [[ "${#selected_names[@]}" -eq 0 ]]; then
    fail "No applications were selected."
  fi

  for name in "${selected_names[@]}"; do
    entry="$(get_app_json_by_name "$name")"
    if [[ -z "$entry" ]]; then
      fail "Catalog entry not found for: $name"
    fi
    install_from_entry "$entry"
  done

  log "Installation completed."
  osascript -e 'display dialog "Installation completed." buttons {"OK"} default button "OK" with title "macOS Deployment"'
}

main "$@"
