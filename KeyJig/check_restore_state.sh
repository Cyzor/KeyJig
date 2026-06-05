#!/bin/sh
set -euo pipefail

# Prints saved-state, preferences, and application support files related to KeyJig
# Usage: ./KeyJig/check_restore_state.sh

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFO_PLIST="$REPO_ROOT/KeyJig/Info.plist"

if [ ! -f "$INFO_PLIST" ]; then
  echo "Info.plist not found at $INFO_PLIST"
  exit 1
fi

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST" 2>/dev/null || true)
if [ -z "$BUNDLE_ID" ]; then
  echo "Failed to read CFBundleIdentifier from $INFO_PLIST"
  exit 1
fi

echo "Bundle identifier: $BUNDLE_ID"

PREFS=~/Library/Preferences/$BUNDLE_ID.plist
SAVED=~/Library/Saved\ Application\ State/$BUNDLE_ID.savedState
APP_SUPPORT=~/Library/Application\ Support/$BUNDLE_ID/RestoredWindows

echo "\nPreferences plist: $PREFS"
if [ -f "$PREFS" ]; then
  echo "  exists — modified: $(stat -f '%Sm' "$PREFS")"
else
  echo "  missing"
fi

echo "\nSaved-state bundle: $SAVED"
if [ -d "$SAVED" ]; then
  echo "  exists — contents:"
  ls -la "$SAVED" | sed -n '1,200p' | sed 's/^/    /'
else
  echo "  missing"
fi

echo "\nApplication Support restored files: $APP_SUPPORT"
if [ -d "$APP_SUPPORT" ]; then
  ls -la "$APP_SUPPORT" | sed -n '1,200p' | sed 's/^/    /'
else
  echo "  none"
fi

echo "\nPer-window keys in preferences (MainWindow-*-svgURL / -svgAppSupportPath / -previewPDFPath):"
# Dump user defaults for the bundle and grep
if defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
  defaults read "$BUNDLE_ID" | sed 's/,$//' | sed 's/^/    /' | egrep 'MainWindow-.*(svgURL|svgAppSupportPath|previewPDFPath)' || true
else
  echo "    (no domain or unreadable)"
fi

exit 0
