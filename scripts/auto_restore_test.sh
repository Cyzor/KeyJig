#!/bin/bash
set -euo pipefail

# Automated restore test for KeyJig (best-effort).
# Usage: ./KeyJig/auto_restore_test.sh /path/to/KeyJig.app /path/to/sample1.svg /path/to/sample2.svg
# Requires Accessibility permission for System Events to send menu keystrokes.

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 /path/to/KeyJig.app /path/to/sample1.svg /path/to/sample2.svg"
  exit 2
fi

APP_PATH="$1"
SVG1="$2"
SVG2="$3"

if [ ! -d "$APP_PATH" ]; then
  echo "App not found at $APP_PATH"
  exit 1
fi

if [ ! -f "$SVG1" ] || [ ! -f "$SVG2" ]; then
  echo "SVG sample files not found"
  exit 1
fi

APP_NAME="$(basename "$APP_PATH" .app)"

echo "Killing running $APP_NAME (if any)"
pkill -x "$APP_NAME" || true
sleep 1

echo "Launching app"
open -a "$APP_PATH"
sleep 2

echo "Open first SVG into app (will go to primary window)"
open -a "$APP_PATH" "$SVG1"
sleep 1

echo "Create a new viewer window (File -> New Viewer) via Cmd-Shift-N"
osascript <<AppleScript
tell application "System Events"
  tell application process "$APP_NAME"
    set frontmost to true
  end tell
end tell

tell application "$APP_NAME" to activate

-- Requires accessibility permission for System Events to send keystrokes
tell application "System Events"
  keystroke "N" using {command down, shift down}
end tell
AppleScript

sleep 1

echo "Open second SVG (should go into the new frontmost viewer)"
open -a "$APP_PATH" "$SVG2"
sleep 1

echo "Quit app cleanly"
osascript -e "tell application \"$APP_NAME\" to quit"

sleep 2

echo "Saved-state / prefs snapshot (after quit):"
./KeyJig/check_restore_state.sh || true

echo "Relaunching app to observe restore"
open -a "$APP_PATH"

sleep 4

echo "Attempting to count windows via System Events (requires Accessibility permission)"
osascript -e "tell application \"System Events\" to count windows of application process \"$APP_NAME\"" || true

# Show diagnostics via app menu (help -> Show Diagnostics). This also requires Accessibility
osascript <<AppleScript || true
tell application "$APP_NAME" to activate
tell application "System Events"
  tell process "$APP_NAME"
    -- choose Help menu (works only if app is frontmost and menu exists)
    click menu item "Show Diagnostics" of menu 1 of menu item "Help" of menu bar 1
  end tell
end tell
AppleScript

echo "Done. Inspect the diagnostics window or the Console.app logs for details."

exit 0
