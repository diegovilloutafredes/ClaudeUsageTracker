#!/bin/bash
# Double-click this file in Finder to install ClaudeUsageTracker.

APP_NAME="ClaudeUsageTracker.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$SCRIPT_DIR/$APP_NAME"
APP_DEST="/Applications/$APP_NAME"

if [ ! -d "$APP_SRC" ]; then
    osascript -e 'display alert "Installation failed" message "ClaudeUsageTracker.app must be in the same folder as this installer." as critical'
    exit 1
fi

# Remove existing version so Launch Services does not cache the old binary
if [ -d "$APP_DEST" ]; then
    rm -rf "$APP_DEST"
fi

cp -R "$APP_SRC" "$APP_DEST"

# Strip the quarantine flag Gatekeeper sets on downloaded files
xattr -dr com.apple.quarantine "$APP_DEST"

osascript -e 'display notification "ClaudeUsageTracker installed successfully." with title "Installation complete"'

open "$APP_DEST"
