#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_JSON_URL="${APP_JSON_URL:-}"
APP_JSON_FILE="${APP_JSON_FILE:-$SCRIPT_DIR/apps.json}"
WORKDIR="${WORKDIR:-/tmp/macos-deploy}"
LOG_FILE="${LOG_FILE:-$WORKDIR/install.log}"
VERBOSE=0

mkdir -p "$WORKDIR"
touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

CURRENT_MOUNT_POINT=""
SUDO_KEEPALIVE_PID=""
POST_INSTALL_MESSAGES=()

cleanup() {
  if [[ -n "${SUDO_KEEPALIVE_PID}" ]]; then
    kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "${CURRENT_MOUNT_POINT}" && -d "${CURRENT_MOUNT_POINT}" ]]; then
    hdiutil detach "$CURRENT_MOUNT_POINT" -quiet || true
  fi
}
trap cleanup EXIT

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

debug() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    log "DEBUG: $*"
  fi
}

fail() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -v, --verbose   Enable verbose output
  -h, --help      Show this help message
EOF
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -v|--verbose)
        VERBOSE=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
    shift
  done
}

require_sudo() {
  if [[ "${EUID}" -ne 0 ]]; then
    sudo -v || fail "Unable to obtain sudo privileges."
  fi
}

start_sudo_keepalive() {
  if [[ "${EUID}" -eq 0 ]]; then
    return
  fi

  log "Requesting administrator privileges..."
  sudo -v || fail "Unable to obtain sudo privileges."

  while true; do
    sleep 60
    sudo -n true >/dev/null 2>&1 || exit
  done &

  SUDO_KEEPALIVE_PID="$!"
  debug "Started sudo keepalive process with PID: $SUDO_KEEPALIVE_PID"
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
  debug "Using Homebrew binary: $brew_bin"
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

is_rosetta_installed() {
  pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1
}

is_filevault_enabled() {
  fdesetup status | grep -q "FileVault is On."
}

user_exists() {
  local username="$1"
  id -u "$username" >/dev/null 2>&1
}

user_is_admin() {
  local username="$1"
  dseditgroup -o checkmember -m "$username" admin | grep -q "yes"
}

create_local_user() {
  local username="$1"
  local password="$2"
  local is_admin="$3"
  local command_status=0

  require_sudo

  if [[ "$is_admin" == "yes" ]]; then
    log "Creating local administrator account: $username"
    sudo sysadminctl -addUser "$username" -password "$password" -admin || command_status=$?
  else
    log "Creating local standard account: $username"
    sudo sysadminctl -addUser "$username" -password "$password" || command_status=$?
  fi

  if ! user_exists "$username"; then
    debug "User creation verification failed for '$username' (sysadminctl exit code: $command_status)"
    return 1
  fi

  if [[ "$is_admin" == "yes" ]] && ! user_is_admin "$username"; then
    debug "Admin rights verification failed for '$username' (sysadminctl exit code: $command_status)"
    return 1
  fi

  return 0
}

grant_secure_token_to_user() {
  local username="$1"
  local password="$2"
  local token_admin_user="$3"
  local token_admin_password="$4"

  require_sudo
  log "Granting a Secure Token to user: $username"
  if sudo sysadminctl -secureTokenOn "$username" -password "$password" -adminUser "$token_admin_user" -adminPassword "$token_admin_password"; then
    return 0
  fi

  return 1
}

prompt_user_creation() {
  local reply
  local username
  local password
  local password_confirm
  local admin_reply
  local token_admin_user
  local token_admin_password
  local is_admin="no"

  printf "Do you want to create a local user now? [y/N] "
  read -r reply

  case "$reply" in
    [yY]|[yY][eE][sS])
      ;;
    *)
      log "User creation skipped."
      return
      ;;
  esac

  while true; do
    printf "Enter the username to create: "
    read -r username

    if [[ -z "$username" ]]; then
      log "Username cannot be empty."
      continue
    fi

    if user_exists "$username"; then
      log "User already exists: $username"
      continue
    fi

    break
  done

  while true; do
    read -r -s -p "Enter the password for $username: " password
    printf "\n"
    read -r -s -p "Confirm the password for $username: " password_confirm
    printf "\n"

    if [[ -z "$password" ]]; then
      log "Password cannot be empty."
      continue
    fi

    if [[ "$password" != "$password_confirm" ]]; then
      log "Passwords do not match. Please try again."
      continue
    fi

    break
  done

  printf "Should this user have administrator rights? [y/N] "
  read -r admin_reply

  case "$admin_reply" in
    [yY]|[yY][eE][sS])
      is_admin="yes"
      ;;
  esac

  debug "Creating user '$username' with admin rights: $is_admin"
  if ! create_local_user "$username" "$password" "$is_admin"; then
    log "ERROR: Failed to create user: $username"
    log "Skipping Secure Token setup and continuing with Rosetta 2 check."
    return
  fi

  if [[ "$is_admin" == "yes" ]]; then
    while true; do
      printf "Enter the username of an existing Secure Token-enabled administrator: "
      read -r token_admin_user

      if [[ -z "$token_admin_user" ]]; then
        log "Administrator username cannot be empty."
        continue
      fi

      if ! user_exists "$token_admin_user"; then
        log "Administrator user not found: $token_admin_user"
        continue
      fi

      break
    done

    while true; do
      read -r -s -p "Enter the password for $token_admin_user: " token_admin_password
      printf "\n"

      if [[ -z "$token_admin_password" ]]; then
        log "Administrator password cannot be empty."
        continue
      fi

      break
    done

    debug "Granting Secure Token to '$username' using administrator '$token_admin_user'"
    grant_secure_token_to_user "$username" "$password" "$token_admin_user" "$token_admin_password"
  fi
}

prompt_filevault_enable() {
  local reply

  if is_filevault_enabled; then
    log "FileVault is already enabled."
    return
  fi

  printf "FileVault is disabled. Do you want to enable it now? [y/N] "
  read -r reply

  case "$reply" in
    [yY]|[yY][eE][sS])
      require_sudo
      log "You will need to enter the login and password of an administrator account."
      log "Enabling FileVault and saving the recovery information to ~/filevault.plist"
      sudo fdesetup enable -outputplist > "$HOME/filevault.plist"
      log "FileVault has been enabled."
      log "The plist file can be retrieved at $HOME/filevault.plist"
      ;;
    *)
      log "FileVault activation skipped."
      ;;
  esac
}

prompt_machine_name_setup() {
  local reply
  local machine_name

  printf "Do you want to set the machine name now? [y/N] "
  read -r reply

  case "$reply" in
    [yY]|[yY][eE][sS])
      ;;
    *)
      log "Machine name setup skipped."
      return
      ;;
  esac

  while true; do
    printf "Enter the machine name: "
    read -r machine_name

    if [[ -z "$machine_name" ]]; then
      log "Machine name cannot be empty."
      continue
    fi

    break
  done

  require_sudo
  log "Setting machine name to: $machine_name"
  sudo scutil --set HostName "$machine_name"
  sudo scutil --set LocalHostName "$machine_name"
  sudo scutil --set ComputerName "$machine_name"
}

prompt_rosetta_install() {
  local reply

  if [[ "$(uname -m)" != "arm64" ]]; then
    log "Rosetta 2 is not required on this Mac architecture."
    return
  fi

  if is_rosetta_installed; then
    log "Rosetta 2 is already installed."
    return
  fi

  printf "Do you want to install Rosetta 2 now? [y/N] "
  read -r reply

  case "$reply" in
    [yY]|[yY][eE][sS])
      require_sudo
      log "Installing Rosetta 2..."
      sudo softwareupdate --install-rosetta --agree-to-license
      ;;
    *)
      log "Rosetta 2 installation skipped."
      ;;
  esac
}

fetch_json_if_needed() {
  if [[ -n "$APP_JSON_URL" ]]; then
    log "Downloading JSON catalog from $APP_JSON_URL"
    curl -fsSL "$APP_JSON_URL" -o "$WORKDIR/apps.json"
    APP_JSON_FILE="$WORKDIR/apps.json"
  fi

  [[ -f "$APP_JSON_FILE" ]] || fail "JSON file not found: $APP_JSON_FILE"
  debug "Using JSON catalog: $APP_JSON_FILE"
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
  debug "Downloading $url to $output"
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

store_post_install_message() {
  local app_name="$1"
  local message="$2"

  if [[ -z "$message" ]]; then
    return 0
  fi

  POST_INSTALL_MESSAGES+=("${app_name}|||${message}")
}

show_post_install_messages() {
  local entry
  local app_name
  local message

  [[ "${#POST_INSTALL_MESSAGES[@]}" -gt 0 ]] || return

  log "Post-install messages:"
  for entry in "${POST_INSTALL_MESSAGES[@]}"; do
    app_name="${entry%%|||*}"
    message="${entry#*|||}"
    printf '\033[1m%s\033[0m : %s\n' "$app_name" "$message"
  done
}

resolve_download_path() {
  local name="$1"
  local default_extension="$2"
  local download_name="${3:-}"

  if [[ -n "$download_name" ]]; then
    printf '%s/%s\n' "$WORKDIR" "$download_name"
    return
  fi

  printf '%s/%s.%s\n' "$WORKDIR" "${name// /_}" "$default_extension"
}

install_from_entry() {
  local entry="$1"
  local name
  local type
  local source
  local app_name
  local pkg_name
  local download_name
  local post_install_message
  local tmpfile

  name="$(printf '%s' "$entry" | jq -r '.name')"
  type="$(printf '%s' "$entry" | jq -r '.type')"
  source="$(printf '%s' "$entry" | jq -r '.source')"
  app_name="$(printf '%s' "$entry" | jq -r '.app_name // empty')"
  pkg_name="$(printf '%s' "$entry" | jq -r '.pkg_name // empty')"
  download_name="$(printf '%s' "$entry" | jq -r '.download_name // empty')"
  post_install_message="$(printf '%s' "$entry" | jq -r '.post_install_message // empty')"

  log "=== Processing: $name ($type) ==="
  debug "Entry source: $source"
  debug "Entry app_name: ${app_name:-<empty>}"
  debug "Entry pkg_name: ${pkg_name:-<empty>}"
  debug "Entry download_name: ${download_name:-<empty>}"
  debug "Entry post_install_message: ${post_install_message:-<empty>}"

  case "$type" in
    brew_formula)
      install_brew_formula "$source"
      ;;
    brew_cask)
      install_brew_cask "$source"
      ;;
    pkg)
      tmpfile="$(resolve_download_path "$name" "pkg" "$download_name")"
      download_file "$source" "$tmpfile"
      install_pkg_file "$tmpfile"
      ;;
    dmg_app)
      if [[ -z "$app_name" ]]; then
        fail "app_name is required for $name"
      fi
      tmpfile="$(resolve_download_path "$name" "dmg" "$download_name")"
      download_file "$source" "$tmpfile"
      install_dmg_app "$tmpfile" "$app_name"
      ;;
    dmg_pkg)
      if [[ -z "$pkg_name" ]]; then
        fail "pkg_name is required for $name"
      fi
      tmpfile="$(resolve_download_path "$name" "dmg" "$download_name")"
      download_file "$source" "$tmpfile"
      install_dmg_pkg "$tmpfile" "$pkg_name"
      ;;
    mobileconfig)
      tmpfile="$(resolve_download_path "$name" "mobileconfig" "$download_name")"
      download_file "$source" "$tmpfile"
      install_mobileconfig "$tmpfile"
      ;;
    *)
      fail "Unknown type for $name: $type"
      ;;
  esac

  store_post_install_message "$name" "$post_install_message"
}

main() {
  local selected_raw
  local name
  local entry
  local line
  local app_names=()
  local selected_names=()

  parse_args "$@"
  log "Starting macOS deployment"
  debug "Verbose mode enabled."
  debug "Script directory: $SCRIPT_DIR"
  debug "Working directory: $WORKDIR"
  debug "Log file: $LOG_FILE"

  start_sudo_keepalive

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

  debug "Loaded ${#app_names[@]} application(s) from catalog."

  prompt_user_creation
  prompt_filevault_enable
  prompt_machine_name_setup
  prompt_rosetta_install

  selected_raw="$(show_selection_gui "${app_names[@]}")"

  if [[ "$selected_raw" == "__CANCELLED__" ]]; then
    log "Selection cancelled by the user."
    exit 0
  fi

  selected_raw="${selected_raw//|||/$'\n'}"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    selected_names+=("$line")
  done <<< "$selected_raw"

  if [[ "${#selected_names[@]}" -eq 0 ]]; then
    fail "No applications were selected."
  fi

  debug "Selected applications: ${selected_names[*]}"

  for name in "${selected_names[@]}"; do
    entry="$(get_app_json_by_name "$name")"
    if [[ -z "$entry" ]]; then
      fail "Catalog entry not found for: $name"
    fi
    install_from_entry "$entry"
  done

  log "Installation completed."
  show_post_install_messages
  osascript -e 'display dialog "Installation completed." buttons {"OK"} default button "OK" with title "macOS Deployment"'
}

main "$@"
