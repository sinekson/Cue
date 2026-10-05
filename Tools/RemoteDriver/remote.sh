#!/bin/zsh
# Real Siri Remote presses on the booted tvOS simulator's Cue app.
#   Tools/RemoteDriver/remote.sh "down,down,shot:episodes,up,focus" [launch args…]
# Launch args given → Cue is relaunched with them first. Screenshots go to
# $SHOTS (default: this folder's shots/). Prints the REMOTE lines only.
set -eu
here=${0:A:h}
keys=$1; shift
shots=${SHOTS:-$here/shots}
mkdir -p "$shots"
cd "$here"
[[ -d RemoteDriver.xcodeproj ]] || xcodegen generate --quiet
udid=$(xcrun simctl list devices booted | grep -m1 -oE '[0-9A-F-]{36}')
TEST_RUNNER_KEYS="$keys" TEST_RUNNER_LAUNCH_ARGS="$*" TEST_RUNNER_SHOTS="$shots" \
TEST_RUNNER_STEP_PAUSE="${STEP_PAUSE:-0.6}" \
xcodebuild test -project RemoteDriver.xcodeproj -scheme RemoteDriver \
  -destination "id=$udid" -derivedDataPath "$here/.build" 2>&1 \
  | grep -E "REMOTE|error:|Failed|failed:" || true
