#!/usr/bin/env bash
# Battery ETA — glanceable time-to-empty in the macOS menu bar.
#
#   curl -fsSL https://raw.githubusercontent.com/hologram2016/macos-battery-eta/main/install.sh | bash
#
# Safer (read it first):
#
#   curl -fsSL https://raw.githubusercontent.com/hologram2016/macos-battery-eta/main/install.sh -o /tmp/install-battery-eta.sh
#   less /tmp/install-battery-eta.sh
#   bash /tmp/install-battery-eta.sh
#
# Downloads a prebuilt universal app. No Xcode, no Homebrew, no sudo.
# User-space only: ~/Applications + a login LaunchAgent.
set -euo pipefail

REPO="${BATTERY_ETA_REPO:-hologram2016/macos-battery-eta}"
ASSET="${BATTERY_ETA_ASSET:-BatteryETA.zip}"
APP_NAME="Battery ETA"
EXEC_NAME="BatteryETA"
LABEL="com.batteryeta.app"
INSTALL_DIR="${BATTERY_ETA_APP_DIR:-$HOME/Applications}"
INSTALLED="$INSTALL_DIR/${APP_NAME}.app"
AGENT="$HOME/Library/LaunchAgents/${LABEL}.plist"
HELPER="$HOME/bin/battery-eta"

ZIP_URL="${BATTERY_ETA_ZIP_URL:-https://github.com/${REPO}/releases/latest/download/${ASSET}}"

die() { echo "error: $*" >&2; exit 1; }

uid_domain() { echo "gui/$(id -u)"; }
job_id() { echo "$(uid_domain)/${LABEL}"; }

need_macos() {
  [[ "$(uname -s)" == Darwin ]] || die "macOS only (found $(uname -s))"
  local ver major
  ver="$(sw_vers -productVersion 2>/dev/null || true)"
  major="${ver%%.*}"
  [[ -n "$major" && "$major" -ge 12 ]] || die "macOS 12 or newer required (found ${ver:-unknown})"
}

warn_if_no_battery() {
  if ! /usr/sbin/ioreg -rn AppleSmartBattery >/dev/null 2>&1; then
    echo "note: no internal battery found. This is meant for laptops; the app will quit on a desktop."
  fi
}

bootout_agent() {
  launchctl bootout "$(job_id)" 2>/dev/null || true
  launchctl unload "$AGENT" 2>/dev/null || true
}

stop_app() {
  bootout_agent
  if pgrep -x "$EXEC_NAME" >/dev/null 2>&1; then
    pkill -x "$EXEC_NAME" || true
    sleep 0.3
  fi
}

write_agent() {
  local exe="$INSTALLED/Contents/MacOS/$EXEC_NAME"
  mkdir -p "$(dirname "$AGENT")"
  cat >"$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${exe}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ThrottleInterval</key>
	<integer>5</integer>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
EOF
}

start_app() {
  [[ -x "$INSTALLED/Contents/MacOS/$EXEC_NAME" ]] || die "app not installed"
  [[ -f "$AGENT" ]] || write_agent
  bootout_agent
  launchctl enable "$(job_id)" 2>/dev/null || true
  if ! launchctl bootstrap "$(uid_domain)" "$AGENT" 2>/dev/null; then
    launchctl load -w "$AGENT" 2>/dev/null || true
  fi
  launchctl kickstart -k "$(job_id)" 2>/dev/null || true
  if ! pgrep -x "$EXEC_NAME" >/dev/null 2>&1; then
    open -g -a "$INSTALLED"
  fi
}

write_helper() {
  mkdir -p "$HOME/bin"
  cat >"$HELPER" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
APP_NAME="Battery ETA"
EXEC_NAME="BatteryETA"
LABEL="com.batteryeta.app"
INSTALLED="${BATTERY_ETA_APP_DIR:-$HOME/Applications}/${APP_NAME}.app"
AGENT="$HOME/Library/LaunchAgents/${LABEL}.plist"
uid_domain() { echo "gui/$(id -u)"; }
job_id() { echo "$(uid_domain)/${LABEL}"; }
cmd="${1:-status}"
case "$cmd" in
  stop)
    launchctl bootout "$(job_id)" 2>/dev/null || true
    launchctl unload "$AGENT" 2>/dev/null || true
    pkill -x "$EXEC_NAME" 2>/dev/null || true
    ;;
  start)
    launchctl enable "$(job_id)" 2>/dev/null || true
    launchctl bootstrap "$(uid_domain)" "$AGENT" 2>/dev/null \
      || launchctl load -w "$AGENT" 2>/dev/null || true
    launchctl kickstart -k "$(job_id)" 2>/dev/null || true
    pgrep -x "$EXEC_NAME" >/dev/null || open -g -a "$INSTALLED"
    ;;
  uninstall)
    launchctl bootout "$(job_id)" 2>/dev/null || true
    launchctl unload "$AGENT" 2>/dev/null || true
    launchctl disable "$(job_id)" 2>/dev/null || true
    pkill -x "$EXEC_NAME" 2>/dev/null || true
    rm -f "$AGENT"
    rm -rf "$INSTALLED"
    rm -f "$HOME/bin/battery-eta"
    echo "Removed Battery ETA."
    ;;
  status|*)
    if pgrep -x "$EXEC_NAME" >/dev/null 2>&1; then
      echo "running pid=$(pgrep -x "$EXEC_NAME")"
    else
      echo "not running"
    fi
    [[ -d "$INSTALLED" ]] && echo "app: $INSTALLED" || echo "app: not installed"
    [[ -f "$AGENT" ]] && echo "agent: $AGENT" || echo "agent: not installed"
    if [[ -x "$INSTALLED/Contents/MacOS/$EXEC_NAME" ]]; then
      "$INSTALLED/Contents/MacOS/$EXEC_NAME" --once --verbose
    fi
    ;;
esac
HELPER
  chmod +x "$HELPER"
}

install_prebuilt() {
  need_macos
  warn_if_no_battery

  local stage zip app
  stage="$(mktemp -d)"
  zip="$stage/$ASSET"
  echo "Downloading $ZIP_URL"
  curl -fsSL --retry 3 --retry-delay 1 "$ZIP_URL" -o "$zip" \
    || die "download failed (no release yet, or $REPO is not public)"
  ditto -x -k "$zip" "$stage" \
    || unzip -q "$zip" -d "$stage"
  app="$(find "$stage" -name "${APP_NAME}.app" -type d -maxdepth 3 | head -1)"
  [[ -n "$app" && -x "$app/Contents/MacOS/$EXEC_NAME" ]] \
    || die "zip did not contain ${APP_NAME}.app"

  mkdir -p "$INSTALL_DIR"
  stop_app
  rm -rf "$INSTALLED"
  ditto "$app" "$INSTALLED"
  xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$INSTALLED" >/dev/null 2>&1 || true
  fi
  write_agent
  write_helper
  start_app
  rm -rf "$stage"

  echo "Installed: $INSTALLED"
  echo "LaunchAgent: $AGENT"
  echo "Starts at every login after boot. Menu bar: 2:14 / 48m / AC."
  case ":${PATH}:" in
    *":$HOME/bin:"*) ;;
    *)
      echo "Note: $HOME/bin is not on PATH. Menu bar still works."
      echo "      Optional:  export PATH=\"\$HOME/bin:\$PATH\""
      ;;
  esac
}

cmd_uninstall() {
  stop_app
  launchctl disable "$(job_id)" 2>/dev/null || true
  rm -f "$AGENT"
  rm -rf "$INSTALLED"
  if [[ -f "$HELPER" ]]; then
    rm -f "$HELPER"
  fi
  echo "Removed Battery ETA."
}

case "${1:-install}" in
  -h|--help|help)
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true
    echo
    echo "install.sh          download the prebuilt app and start at login"
    echo "install.sh uninstall"
    ;;
  uninstall) cmd_uninstall ;;
  install) install_prebuilt ;;
  *)
    echo "unknown command: $1" >&2
    exit 2
    ;;
esac
