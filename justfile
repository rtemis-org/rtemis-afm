# rtemis-afm tasks. Run `just` to list.
#
# A Swift package with no Xcode project: `swift build`, `swift test` and
# `swift run` are the whole workflow, and every recipe here is one of them
# with the flags the CI and release workflows use, so a local run answers
# the same question CI will. There is no `fmt`: the sources predate a
# formatter and `swift format` would rewrite every file, which is a change
# of its own.

# What the binary reports, and what a release tag must match.
version := `awk -F'"' '/static let version/ { print $2; exit }' Sources/RtemisAFM/Version.swift`

# Where `afm.sh` installs the binary (no sudo, no PATH edits); `install`
# puts a source build in the same place so the launcher and the Help page's
# instructions find it. Override as the installer does.
prefix := env("RTEMIS_AFM_PREFIX", env("HOME") / ".rtemis/bin")

# The port a running bridge is asked on. rtemislive defaults to the same.
port := env("RTEMIS_AFM_PORT", "1977")

# rtemislive's checkout: it serves `afm.sh` at live.rtemis.org/afm.sh from
# its `public/`, and that copy is a copy (`docs/maintenance.md`).
live := env("LIVE_DIR", env("HOME") / "Code/live")

# List available recipes.
default:
    @just --list

# ── Build ────────────────────────────────────────────────────────────────────

# Compile the debug build of every target.
build:
    swift build

# Compile the release binary, as the release workflow does.
build-release:
    swift build -c release --product rtemis-afm

# Remove build products (`.build/`) and packaged releases (`dist/`).
clean:
    swift package clean
    rm -rf dist

# ── Verify ───────────────────────────────────────────────────────────────────

# Build and run the unit tests: what CI runs. Never edits sources.
check: build test

# Run the unit tests (no Apple Intelligence needed).
test:
    swift test

# Probe the FoundationModels framework against the real model. Run after
# every macOS or Xcode update; see `Sources/afm-spike/README.md`.
[doc("Probe the framework against the real model (after macOS/Xcode updates).")]
spike:
    swift run afm-spike

# ── Run ──────────────────────────────────────────────────────────────────────

# Serve from source, release build, in the foreground. Extra flags go to
# `serve` (`just serve --verbose`, `just serve --port 1978`). Stop a copy
# already on the port first (`just stop`) or this one exits at bind.
[doc("Serve from source (release build) in the foreground; flags go to `serve`.")]
serve *flags:
    swift run -c release rtemis-afm serve {{ flags }}

# Serve the debug build with request logging, for working on the bridge.
dev *flags:
    swift run rtemis-afm serve --verbose {{ flags }}

# Stop every running bridge — Homebrew's, the installed one, or one started
# from source — and wait for it to go.
[doc("Stop every running bridge (Homebrew, installed or from source) and wait for it to go.")]
stop:
    #!/usr/bin/env bash
    pkill -x rtemis-afm || exit 0
    for _ in $(seq 1 50); do pgrep -x rtemis-afm >/dev/null || exit 0; sleep 0.2; done
    pkill -9 -x rtemis-afm || true

# Ask the bridge on the port for its health; exit 0 when the model is available.
status:
    swift run -c release rtemis-afm status --port {{ port }}

# ── Install and release ──────────────────────────────────────────────────────

# Build the release binary, sign it ad hoc as the release workflow does, and
# copy it to the installer's prefix. A launcher that starts the Homebrew copy
# keeps doing so; `just stop` then `just serve` runs this one instead.
[doc("Build, sign (ad hoc) and copy the release binary to the installer's prefix.")]
install: build-release
    #!/usr/bin/env bash
    set -euo pipefail
    bin="$(swift build -c release --show-bin-path)/rtemis-afm"
    codesign --force --sign - --timestamp=none "$bin"
    mkdir -p "{{ prefix }}"
    cp "$bin" "{{ prefix }}/rtemis-afm"
    echo "Installed rtemis-afm {{ version }} to {{ prefix }}/rtemis-afm"

# Everything the release workflow does before it uploads: test, build,
# sign, package into `dist/`, checksum, and smoke-test the packaged binary.
# Run it before tagging `v{{ version }}`.
[doc("Test, build, sign, package into dist/ and smoke-test, as the release workflow does.")]
release-check: test build-release
    #!/usr/bin/env bash
    set -euo pipefail
    bin="$(swift build -c release --show-bin-path)/rtemis-afm"
    codesign --force --sign - --timestamp=none "$bin"
    codesign --verify --verbose "$bin"
    stage="$(mktemp -d)/rtemis-afm-{{ version }}"
    mkdir -p "$stage" dist
    cp "$bin" README.md LICENSE "$stage/"
    asset="dist/rtemis-afm-{{ version }}-macos-arm64.tar.gz"
    tar -C "$(dirname "$stage")" -czf "$asset" "rtemis-afm-{{ version }}"
    (cd dist && shasum -a 256 "$(basename "$asset")" > SHA256SUMS && cat SHA256SUMS)
    smoke="$(mktemp -d)"
    tar -xzf "$asset" -C "$smoke"
    "$smoke/rtemis-afm-{{ version }}/rtemis-afm" version | grep -x "{{ version }}"
    grep -q "^## {{ version }} — " CHANGELOG.md || { echo "CHANGELOG.md has no dated '## {{ version }}' section"; exit 1; }
    ! grep -q '^## Unreleased$' CHANGELOG.md || { echo "CHANGELOG.md still has an Unreleased section: run 'just bump <version>' first"; exit 1; }
    echo "Ready to tag v{{ version }}"

# Print the version the binary reports.
version:
    @echo {{ version }}

# Cut a release: set the constant the binary reports and turn the
# changelog's `## Unreleased` section into `## <new> — <today>`, so a
# heading never says "unreleased" once its tag exists. Then `release-check`,
# commit, tag `v<new>` and push the tag: the workflow builds, publishes the
# release with that section as its notes, and bumps the Homebrew tap.
[doc("Set Version.swift and date the changelog's Unreleased section as <new>.")]
bump new:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "{{ new }}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a version: {{ new }}"; exit 1; }
    [[ "{{ new }}" != "{{ version }}" ]] || { echo "already at {{ version }}"; exit 1; }
    grep -q '^## Unreleased$' CHANGELOG.md || { echo "CHANGELOG.md has no '## Unreleased' section to release"; exit 1; }
    sed -i '' 's/version = "[^"]*"/version = "{{ new }}"/' Sources/RtemisAFM/Version.swift
    sed -i '' "s/^## Unreleased$/## {{ new }} — $(date +%Y-%m-%d)/" CHANGELOG.md
    echo "{{ version }} → {{ new }}. Next: just release-check, commit, then tag v{{ new }} and push the tag."

# Update the Homebrew copy on this Mac to the tap's latest release (what a
# tag's workflow published), and show what it now reports.
[doc("brew update + upgrade rtemis-afm from the tap; print the installed version.")]
brew-upgrade:
    brew update
    brew upgrade rtemis-afm || true
    @echo "Homebrew rtemis-afm: $(brew list --versions rtemis-afm | cut -d' ' -f2) (source tree: {{ version }})"

# ── Installer ────────────────────────────────────────────────────────────────

# Copy `scripts/afm.sh` to rtemislive's `public/`, which serves it at
# live.rtemis.org/afm.sh.
[doc("Copy scripts/afm.sh to rtemislive's public/ (served at live.rtemis.org/afm.sh).")]
sync-afm-sh:
    cp scripts/afm.sh "{{ live }}/public/afm.sh"

# Fail if rtemislive's copy of `afm.sh` differs from the source here.
check-afm-sh:
    diff -u "{{ live }}/public/afm.sh" scripts/afm.sh
