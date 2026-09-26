#!/usr/bin/env bash
#
# Omarchy-Pixel-Effect — installer for the Omarchy SUPER+SPACE menu pixel wipe
# and the omakase-pixel palette theme.
#
# This repo ships exactly two things:
#   omakase-pixel/        the palette theme (colors.toml, lock colors, wallpaper, ...)
#   omakase-pixel.menu/   the SUPER+SPACE Quickshell menu plugin (pixel wipe + app fallback)
#
# `omarchy theme install <url>` is NOT the way to install this repo: it clones
# the whole repository to ~/.config/omarchy/themes/<name> and stages the *repo
# root* as a single theme, deriving the theme name from the repository basename
# (which would be "pixel-effect", not the theme's real identity). Instead this
# script mirrors how the theme's own extras installer works: it copies the two
# directories into their real locations and, for the menu, patches shell.json
# to point the bar's menu slot at the plugin.
#
# Everything is under $HOME — no sudo, nothing written outside your user config.
#
#   install.sh              install the theme + the menu (default)
#   install.sh --theme      install the palette theme only
#   install.sh --plugin     install the SUPER+SPACE menu only
#   install.sh --uninstall  remove both and restore the previous shell.json
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEME_SRC="$REPO_DIR/omakase-pixel"
PLUGIN_SRC="$REPO_DIR/omakase-pixel.menu"

THEME_NAME="omakase-pixel"
PLUGIN_ID="omakase-pixel.menu"

THEMES_DIR="$HOME/.config/omarchy/themes"
THEME_DST="$THEMES_DIR/$THEME_NAME"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
PLUGIN_DST="$PLUGINS_DIR/$PLUGIN_ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
SHELL_BACKUP="$SHELL_JSON.omakase-pixel.bak"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m==>\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

DO_THEME=1
DO_PLUGIN=1
DO_UNINSTALL=0
RESTART_SHELL=1

usage() {
  cat <<'EOF'
Usage: install.sh [options]

  (no option)     Install the palette theme AND the SUPER+SPACE menu.
  --theme         Install only the omakase-pixel palette theme.
  --plugin        Install only the omakase-pixel.menu SUPER+SPACE menu.
  --uninstall     Remove the theme + menu and restore the previous shell.json.
  --no-restart    Do not restart the omarchy shell at the end.
  -h, --help      Show this help.

Requires: an Omarchy system (omarchy CLI on PATH), jq, and a git clone of this
repository. Nothing is written outside $HOME.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --theme)      DO_THEME=1; DO_PLUGIN=0 ;;
    --plugin)     DO_THEME=0; DO_PLUGIN=1 ;;
    --uninstall)  DO_UNINSTALL=1 ;;
    --no-restart) RESTART_SHELL=0 ;;
    -h|--help)    usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

require_omarchy() {
  have omarchy || die "the 'omarchy' command is not on PATH — is this an Omarchy system?"
  have jq || die "jq is required to patch shell.json safely (install it with: sudo pacman -S jq)"
}

# Copy the palette theme into the user themes dir, then apply it.
install_theme() {
  [ -d "$THEME_SRC" ] || die "omakase-pixel/ is missing from this checkout"
  [ -f "$THEME_SRC/colors.toml" ] || die "omakase-pixel/colors.toml is missing"

  say "installing the '$THEME_NAME' palette theme -> $THEME_DST"
  mkdir -p "$THEME_DST"
  cp -a "$THEME_SRC/." "$THEME_DST/"

  say "applying theme (omarchy theme set $THEME_NAME)"
  omarchy theme set "$THEME_NAME" || warn "theme set returned non-zero; re-run manually if the palette did not change"
}

# Copy the menu plugin into the user plugins dir, backing up anything that
# currently occupies the same path, then point the bar's menu slot at it.
install_plugin() {
  [ -d "$PLUGIN_SRC" ] || die "omakase-pixel.menu/ is missing from this checkout"
  [ -f "$PLUGIN_SRC/manifest.json" ] || die "omakase-pixel.menu/manifest.json is missing"

  mkdir -p "$PLUGINS_DIR"

  # A re-run on an already-installed tree must not displace its own copy
  # (that would orphan the live plugin under a timestamped name).
  [ -f "$PLUGIN_DST/.installed-by-omarchy-pixel-effect" ] && rm -rf "$PLUGIN_DST"

  # Back up a displaced plugin (same id) so --uninstall can put it back.
  if [ -e "$PLUGIN_DST" ]; then
    local displaced="$PLUGIN_DST.displaced.$(date +%s)"
    say "a plugin already lives at $PLUGIN_DST — moving it to $(basename "$displaced")"
    mv "$PLUGIN_DST" "$displaced"
  fi

  say "installing the '$PLUGIN_ID' menu plugin -> $PLUGIN_DST"
  cp -a "$PLUGIN_SRC" "$PLUGIN_DST"
  touch "$PLUGIN_DST/.installed-by-omarchy-pixel-effect"

  [ -f "$SHELL_JSON" ] || die "shell.json not found at $SHELL_JSON"

  # Snapshot the current shell.json so --uninstall is a clean revert. Only
  # the FIRST install may write the backup: a re-run must not overwrite it
  # with the already-patched file, or --uninstall would restore the patched
  # state instead of the true original.
  if [ -f "$SHELL_BACKUP" ]; then
    say "keeping the original shell.json snapshot from the first install"
  else
    cp -a "$SHELL_JSON" "$SHELL_BACKUP"
    say "backed up shell.json -> $(basename "$SHELL_BACKUP")"
  fi

  # Point the bar's menu slot at the plugin and disable the first-party /
  # stock menu so it does not double-render.
  #   * if the bar left already names our plugin -> leave it (idempotent)
  #   * else replace a stock/hyperlayer menu entry with ours
  #   * else prepend ours to the bar left
  #   * ensure omarchy.menu + hyperlayer.menu are in disabledPlugins,
  #     and that our own id is never disabled
  local filter
  filter='
    .bar.layout.left |= (
      . as $l
      | if ($l | map(.id) | index("omakase-pixel.menu")) != null then $l
        else
          ( $l | map(if .id == "omarchy.menu" or .id == "hyperlayer.menu"
                     then {"id": "omakase-pixel.menu"} else . end) )
          | if (map(.id) | index("omakase-pixel.menu")) != null then .
            else [{"id": "omakase-pixel.menu"}] + .
            end
        end
    )
    # (a fresh shell.json has no disabledPlugins key at all: start from [])
    | .disabledPlugins |= (
        ((. // []) + (["omarchy.menu", "hyperlayer.menu"] - (. // [])))
        | map(select(. != "omakase-pixel.menu"))
      )
  '

  say "patching shell.json (bar menu slot + disabledPlugins)"
  jq "$filter" "$SHELL_JSON" > "$SHELL_JSON.tmp"
  # Only replace the live file if the rewrite is valid JSON.
  jq -e . "$SHELL_JSON.tmp" >/dev/null || die "jq produced invalid shell.json — aborting (original untouched)"
  mv "$SHELL_JSON.tmp" "$SHELL_JSON"

  local left
  left="$(jq -r '.bar.layout.left | map(.id) | join(", ")' "$SHELL_JSON")"
  say "bar left now: $left"
}

restart_shell() {
  [ "$RESTART_SHELL" -eq 1 ] || return 0
  say "restarting the omarchy shell to pick up the new plugin (brief bar flicker)"
  # A plugin rescan is enough for most; a full restart is the reliable fallback.
  if omarchy-shell shell rescanPlugins >/dev/null 2>&1; then
    say "plugin rescan requested"
  else
    omarchy restart shell || warn "could not restart the shell — run: omarchy restart shell"
  fi
}

uninstall() {
  local touched=0

  if [ -e "$PLUGIN_DST/.installed-by-omarchy-pixel-effect" ] || [ -d "$PLUGIN_DST" ]; then
    say "removing the '$PLUGIN_ID' menu plugin"
    rm -rf "$PLUGIN_DST"
    # Restore a displaced plugin if one was parked.
    local displaced
    for displaced in "$PLUGIN_DST".displaced.*; do
      [ -e "$displaced" ] || continue
      say "restoring displaced plugin $(basename "$displaced") -> $PLUGIN_DST"
      mv "$displaced" "$PLUGIN_DST"
      break
    done
    touched=1
  fi

  # Revert shell.json to the pre-install snapshot when we have one.
  if [ -f "$SHELL_BACKUP" ]; then
    say "restoring shell.json from $(basename "$SHELL_BACKUP")"
    cp -a "$SHELL_BACKUP" "$SHELL_JSON"
    rm -f "$SHELL_BACKUP"
    touched=1
  elif [ -f "$SHELL_JSON" ]; then
    warn "no shell.json snapshot found; removing our bar entry + re-enabling the stock menu"
    jq '
      .bar.layout.left |= map(select(.id != "omakase-pixel.menu"))
      | .disabledPlugins |= map(select(. != "omakase-pixel.menu"))
    ' "$SHELL_JSON" > "$SHELL_JSON.tmp" && mv "$SHELL_JSON.tmp" "$SHELL_JSON"
    # Re-enable the first-party menu so the bar has a working slot again.
    jq '.disabledPlugins |= (. - ["omarchy.menu"])' "$SHELL_JSON" > "$SHELL_JSON.tmp" \
      && mv "$SHELL_JSON.tmp" "$SHELL_JSON"
    touched=1
  fi

  if [ -d "$THEME_DST" ]; then
    say "removing the '$THEME_NAME' theme directory"
    rm -rf "$THEME_DST"
    touched=1
    warn "if omakase-pixel was your active theme, pick another now:  omarchy theme list"
  fi

  if [ "$touched" -eq 1 ]; then
    if [ "$RESTART_SHELL" -eq 1 ]; then
      say "restarting the omarchy shell"
      omarchy restart shell || warn "could not restart the shell — run: omarchy restart shell"
    fi
    say "uninstall complete."
  else
    say "nothing to uninstall (already clean)."
  fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

if [ "$DO_UNINSTALL" -eq 1 ]; then
  require_omarchy
  uninstall
  exit 0
fi

require_omarchy
if [ "$DO_THEME" -eq 1 ]; then
  install_theme
fi
if [ "$DO_PLUGIN" -eq 1 ]; then
  install_plugin
  restart_shell
fi
say "done."
if [ "$DO_PLUGIN" -eq 1 ]; then
  say "press SUPER+SPACE — the menu card should reveal with the pixel wipe."
fi
