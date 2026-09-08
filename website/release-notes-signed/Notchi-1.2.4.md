<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
# Notchi 1.2.4

This release adds a setting for which quota the main usage bar shows, a badge for auto permission mode, and a better fit on external displays.

## Usage

- Adds a Main Usage Bar setting in Appearance so the compact bar can show Session or Weekly quota
- Keeps the main bar on the current session's provider, and labels the period when it falls back to the provider's other window
- Shows loading, error, and reconnect states on the bar instead of swapping to the other provider
- Opens the usage detail view on the provider the bar is actually showing
- Drops Codex quota windows whose reset time has already passed, so a lapsed percentage never shows as fresh
- Marks held-over Claude weekly and model quota as stale when a refresh fails

## Sessions

- Shows an Auto badge for sessions running in Claude Code's auto permission mode

## Panel

- Sizes the panel to the menu bar on screens without a notch, so it no longer overhangs window content on external displays
