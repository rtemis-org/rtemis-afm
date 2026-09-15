#!/bin/sh
# afm.sh — install and start rtemis-afm, the bridge between rtemislive and
# Apple's on-device Foundation Model.
#
#   curl -fsSL https://live.rtemis.org/afm.sh | sh
#
# What it does, in order:
#   1. Checks this is an Apple silicon Mac on macOS 26 or later.
#   2. Finds the latest release of rtemis-org/rtemis-afm on GitHub.
#   3. Downloads the release tarball and its SHA256SUMS, and verifies the hash.
#   4. Installs the binary to ~/.rtemis/bin/rtemis-afm (no sudo, no PATH edits).
#   5. Starts it.
#
# Re-running upgrades in place. Environment variables:
#   RTEMIS_AFM_VERSION   install this version (e.g. 0.1.0) instead of the latest
#   RTEMIS_AFM_NO_RUN=1  install only, do not start
#   RTEMIS_AFM_PREFIX    install directory (default ~/.rtemis/bin)
#   RTEMIS_AFM_BASE_URL  where to fetch the tarball and SHA256SUMS from
#                        (for testing a build before it is released)
#
# The source of this file lives at
# https://github.com/rtemis-org/rtemis-afm/blob/main/scripts/afm.sh and is
# copied to rtemislive's public/ so the URL above deploys with the site.
#
# Written for POSIX sh (it is piped to `sh`); no bash-isms.

set -eu

REPO="rtemis-org/rtemis-afm"
PREFIX="${RTEMIS_AFM_PREFIX:-$HOME/.rtemis/bin}"
BIN="$PREFIX/rtemis-afm"

say() { printf '%s\n' "$*"; }
fail() { printf 'afm.sh: %s\n' "$*" >&2; exit 1; }

# --- 1. Platform ---------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || fail "rtemis-afm runs on macOS only."
[ "$(uname -m)" = "arm64" ] || fail "rtemis-afm needs an Apple silicon Mac (this one is $(uname -m)); Apple Intelligence does not run on Intel."

OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
[ "$OS_MAJOR" -ge 26 ] 2>/dev/null || fail "rtemis-afm needs macOS 26 or later (this Mac runs $OS_VERSION)."

command -v curl >/dev/null || fail "curl is required."
command -v shasum >/dev/null || fail "shasum is required."

# --- 2. Version ----------------------------------------------------------

if [ -n "${RTEMIS_AFM_VERSION:-}" ]; then
  VERSION="$RTEMIS_AFM_VERSION"
else
  # The releases API returns JSON; pull `tag_name` out with sed rather than
  # depending on jq being installed.
  TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$TAG" ] || fail "could not find the latest release of $REPO (is GitHub reachable?)."
  VERSION="${TAG#v}"
fi

if [ -x "$BIN" ] && [ "$("$BIN" version 2>/dev/null || true)" = "$VERSION" ]; then
  say "rtemis-afm $VERSION is already installed at $BIN."
else
  # --- 3. Download and verify ---------------------------------------------

  ASSET="rtemis-afm-$VERSION-macos-arm64.tar.gz"
  BASE="${RTEMIS_AFM_BASE_URL:-https://github.com/$REPO/releases/download/v$VERSION}"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT

  say "Downloading rtemis-afm ${VERSION}..."
  curl -fsSL -o "$TMP/$ASSET" "$BASE/$ASSET" || fail "download failed: $BASE/$ASSET"
  curl -fsSL -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS" || fail "download failed: $BASE/SHA256SUMS"

  # `shasum -c` checks every line of the sums file against files in the
  # current directory; only the tarball's line is kept.
  EXPECTED="$(grep " $ASSET\$" "$TMP/SHA256SUMS" | cut -d' ' -f1)"
  [ -n "$EXPECTED" ] || fail "SHA256SUMS has no entry for $ASSET."
  ACTUAL="$(shasum -a 256 "$TMP/$ASSET" | cut -d' ' -f1)"
  [ "$EXPECTED" = "$ACTUAL" ] || fail "checksum mismatch for $ASSET (expected $EXPECTED, got $ACTUAL)."

  # --- 4. Install ----------------------------------------------------------

  tar -xzf "$TMP/$ASSET" -C "$TMP"
  mkdir -p "$PREFIX"
  # Copy then move so a running binary is replaced atomically.
  cp "$TMP/rtemis-afm-$VERSION/rtemis-afm" "$BIN.new"
  chmod 755 "$BIN.new"
  mv -f "$BIN.new" "$BIN"
  say "Installed rtemis-afm $VERSION to $BIN"
fi

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *)
    say ""
    say "To run it later by name, add this line to your shell profile (~/.zshrc):"
    say "  export PATH=\"$PREFIX:\$PATH\""
    ;;
esac

# --- 5. Run ----------------------------------------------------------------

[ -z "${RTEMIS_AFM_NO_RUN:-}" ] || exit 0
say ""
exec "$BIN"
