#!/usr/bin/env bash
#
# Takes an app's store screenshots: the App Store sets on iOS simulators and
# the F-Droid set on an Android emulator (a Pixel). Run it from the app's root,
# through the app's own scripts/store-screenshots.sh, which names the screens:
#
#   scripts/store-screenshots.sh [--device iphone|ipad|android]... [--update-fdroid]
#
# With no --device it takes iphone and ipad. android needs the Android SDK's
# emulator and a JDK (see "The Android emulator" below).
#
# On each device it runs the app's integration_test/store_screenshots_test.dart,
# which puts sample wallets in place and walks through the screens. At each
# screen the test asks for a picture (package:wallet_domain/screenshots.dart,
# StoreShots.capture) and this script takes it with the device's own tool
# (simctl, adb), status bar included, in the light or dark theme as asked.
#
# STORE_SHOTS (set by the app's wrapper) lists the listing's screenshots most
# important first, as <screen>-<theme>. The App Store takes the first 10 of each
# size (its limit); F-Droid takes them all.
#
# Writes build/store_screenshots/<version>/:
#   <device>-test.log                   the test's output, and <device>-failure.png
#                                       when it fails: the screen it stopped on
#   source/<device>/<screen>-<theme>.png
#                                       every capture, as taken
#   app-store/iphone-6.9/NN-<shot>.png  1320 x 2868  } the first 10 of STORE_SHOTS,
#   app-store/iphone-6.5/NN-<shot>.png  1242 x 2688  } numbered in that order, flat
#   app-store/ipad-13/NN-<shot>.png     2064 x 2752  } (no alpha): ready to upload
#   fdroid/NN.png                       every STORE_SHOTS screen from the Pixel, as taken
#
# With --update-fdroid, fdroid/ replaces fastlane/metadata/android/en-US/images/
# phoneScreenshots/. The two-digit names keep F-Droid's order: it sorts names
# as text, so 10.png would come before 2.png.
#
# The simulators: "Store Shots iPhone" (iPhone 17 Pro Max) and "Store Shots
# iPad" (iPad Pro 13-inch), created on first use. Each run restarts the
# simulator, removes the app, resets the keychain and fixes the status bar at
# 9:41 with full signal and battery. The iPad is switched to Full Screen Apps
# (Settings > Multitasking & Gestures) on first use: windowed apps carry a
# resize handle in the corner of every picture. The script never erases a
# device, so its settings stay.
#
# The Android emulator: an AVD named $ANDROID_AVD (default Store_Shots_Pixel_8).
# Create it once (Apple silicon; use x86_64 elsewhere):
#   sdkmanager "emulator" "platform-tools" "system-images;android-35;google_apis;arm64-v8a"
#   avdmanager create avd -n Store_Shots_Pixel_8 -d pixel_8 \
#     -k "system-images;android-35;google_apis;arm64-v8a"
# The script starts it when no emulator is running, removes the app, puts the
# status bar in demo mode (9:41, full Wi-Fi and battery, no cellular or
# notification icons) and
# switches the system theme with `cmd uimode night`.
#
# Environment: STORE_SHOTS, FLUTTER (default: flutter on PATH), ANDROID_HOME
# (default ~/Library/Android/sdk), ANDROID_AVD.
set -euo pipefail

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/store-screenshots"
FLUTTER="${FLUTTER:-flutter}"
TEST=integration_test/store_screenshots_test.dart
DEVICES=()
UPDATE_FDROID=0
APP_STORE_LIMIT=10
# Seconds to wait after the system theme changes, before the picture and before
# the walk goes on: a debug build re-themes every route and animates borders,
# and 2 seconds caught Spice's home with its tab bar still light.
THEME_SETTLE=6

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICES+=("$2"); shift 2 ;;
    --update-fdroid) UPDATE_FDROID=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ ${#DEVICES[@]} -gt 0 ] || DEVICES=(iphone ipad)

[ -f pubspec.yaml ] && [ -f "$TEST" ] || {
  echo "run from an app's root (no $TEST here)" >&2
  exit 1
}
# shellcheck disable=SC2206 # split on whitespace, lines included
SHOTS=(${STORE_SHOTS:?STORE_SHOTS lists the screenshots, most important first})

VERSION="$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' pubspec.yaml)"
BUNDLE="$(sed -n 's/.*PRODUCT_BUNDLE_IDENTIFIER = \([A-Za-z0-9.]*\);/\1/p' \
  ios/Runner.xcodeproj/project.pbxproj | grep -v -i tests | head -1)"
PACKAGE="$(sed -n 's/.*applicationId = "\([A-Za-z0-9._]*\)".*/\1/p' android/app/build.gradle.kts | head -1)"
OUT="build/store_screenshots/$VERSION"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O "$TOOLS/fit.swift" -o "$WORK/fit"

# ----- iOS -----

device_type() {
  case "$1" in
    iphone) echo com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max ;;
    ipad) echo com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB ;;
  esac
}

# The UDID of this script's own simulator for $1, created on first use.
simulator() {
  local name="Store Shots $([ "$1" = ipad ] && echo iPad || echo iPhone)"
  local udid
  udid="$(xcrun simctl list devices -j | /usr/bin/python3 -c '
import json, sys
name = sys.argv[1]
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"] == name and d.get("isAvailable"):
            print(d["udid"]); sys.exit()' "$name")"
  if [ -z "$udid" ]; then
    local runtime
    runtime="$(xcrun simctl list runtimes -j | /usr/bin/python3 -c '
import json, sys
ios = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
print(ios[-1]["identifier"])')"
    udid="$(xcrun simctl create "$name" "$(device_type "$1")" "$runtime")"
  fi
  echo "$udid"
}

capture_ios() {
  local kind="$1" udid log pid shots container request name themes theme
  udid="$(simulator "$kind")"
  shots="$OUT/source/$kind"
  log="$OUT/$kind-test.log"
  rm -rf "$shots" "$OUT/$kind-failure.png"
  mkdir -p "$shots"

  echo "== $kind: preparing simulator $udid"
  # A clean app, not a clean device: the app and its keychain items go, and
  # device settings stay (on the iPad, Multitasking > Full Screen Apps). The
  # restart clears what other apps left behind, like the status bar's link
  # back to the last app.
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b >/dev/null
  if [ "$kind" = ipad ] &&
    [ "$(xcrun simctl spawn "$udid" defaults read com.apple.springboard SBMedusaMultitaskingEnabled 2>/dev/null)" != 0 ]; then
    # Full Screen Apps (Settings > Multitasking & Gestures; this is the
    # setting it writes): a windowed app carries a resize handle in the corner
    # of every picture. SpringBoard reads it at start.
    xcrun simctl spawn "$udid" defaults write com.apple.springboard SBMedusaMultitaskingEnabled -bool false
    xcrun simctl shutdown "$udid"
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b >/dev/null
  fi
  xcrun simctl uninstall "$udid" "$BUNDLE" 2>/dev/null || true
  xcrun simctl keychain "$udid" reset
  xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active \
    --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  xcrun simctl ui "$udid" appearance light

  echo "== $kind: running $TEST (log: $log)"
  "$FLUTTER" test "$TEST" -d "$udid" --dart-define=DEMO_MODE=true >"$log" 2>&1 &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    container="$(xcrun simctl get_app_container "$udid" "$BUNDLE" data 2>/dev/null || true)"
    request="$container/tmp/store_shots/request"
    if [ -n "$container" ] && [ -f "$request" ]; then
      read -r name themes <"$request"
      rm "$request"
      for theme in ${themes//,/ }; do
        xcrun simctl ui "$udid" appearance "$theme"
        sleep "$([ "$theme" = light ] && echo 2 || echo "$THEME_SETTLE")"
        # Into $WORK first: the simulator may not write where the app is (an
        # external drive, without Removable Volumes access), and that failure
        # must not end the run unexplained.
        if ! xcrun simctl io "$udid" screenshot --type=png "$WORK/shot.png" >/dev/null 2>"$WORK/shot.err"; then
          cat "$WORK/shot.err" >&2
          exit 1
        fi
        mv "$WORK/shot.png" "$shots/$name-$theme.png"
        echo "   $name-$theme"
      done
      if [ "$theme" != light ]; then
        xcrun simctl ui "$udid" appearance light
        sleep "$THEME_SETTLE"
      fi
      touch "$container/tmp/store_shots/done"
    fi
    sleep 0.3
  done

  finish "$kind" "$pid" "$log" "$shots"
  xcrun simctl shutdown "$udid"
}

# ----- Android -----

capture_android() {
  local sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}" avd="${ANDROID_AVD:-Store_Shots_Pixel_8}"
  local adb="$sdk/platform-tools/adb" emulator="$sdk/emulator/emulator"
  local serial shots log pid request name themes theme granted=0
  shots="$OUT/source/android"
  log="$OUT/android-test.log"
  rm -rf "$shots" "$OUT/android-failure.png"
  mkdir -p "$shots"

  serial="$("$adb" devices | awk '/^emulator-[0-9]+\tdevice/ {print $1; exit}')"
  if [ -z "$serial" ]; then
    if [ ! -x "$emulator" ] || ! "$emulator" -list-avds | grep -qx "$avd"; then
      echo "no Android emulator running and no AVD $avd: see \"The Android emulator\" in $0" >&2
      exit 1
    fi
    echo "== android: starting $avd"
    "$emulator" -avd "$avd" -no-snapshot-save -no-boot-anim >/dev/null 2>&1 &
    "$adb" wait-for-device
    serial="$("$adb" devices | awk '/^emulator-[0-9]+\tdevice/ {print $1; exit}')"
  fi
  local a=("$adb" -s "$serial")
  until [ "$("${a[@]}" shell getprop sys.boot_completed | tr -d '\r')" = 1 ]; do sleep 2; done

  echo "== android: preparing $serial"
  "${a[@]}" uninstall "$PACKAGE" >/dev/null 2>&1 || true
  demo() { "${a[@]}" shell am broadcast -a com.android.systemui.demo -e command "$@" >/dev/null; }
  # Set again before every picture: System UI ignores `enter` until it has
  # seen sysui_demo_allowed, which on a fresh boot is after the broadcast, and
  # it can say nothing of whether demo mode is on.
  status_bar() {
    demo enter
    demo clock -e hhmm 0941
    demo battery -e level 100 -e plugged false
    demo network -e wifi show -e level 4 -e fully true
    # Hidden: shown, it carries the emulator's own "3G" whatever datatype says.
    demo network -e mobile hide
    demo notifications -e visible false
  }
  "${a[@]}" shell settings put global sysui_demo_allowed 1
  status_bar
  "${a[@]}" shell cmd uimode night no >/dev/null

  echo "== android: running $TEST (log: $log)"
  "$FLUTTER" test "$TEST" -d "$serial" --dart-define=DEMO_MODE=true >"$log" 2>&1 &
  pid=$!

  # The request sits in Directory.systemTemp, which Flutter on Android puts in
  # the app's code_cache directory (not cache/), and `run-as` reaches in a
  # debug build.
  while kill -0 "$pid" 2>/dev/null; do
    if "${a[@]}" shell pm path "$PACKAGE" >/dev/null 2>&1; then
      if [ "$granted" = 0 ]; then
        # Before the app can ask: a permission dialog is the system's, and the
        # test cannot tap it.
        "${a[@]}" shell pm grant "$PACKAGE" android.permission.POST_NOTIFICATIONS 2>/dev/null || true
        granted=1
      fi
      request="$("${a[@]}" shell run-as "$PACKAGE" cat code_cache/store_shots/request 2>/dev/null | tr -d '\r' || true)"
      if [ -n "$request" ]; then
        "${a[@]}" shell run-as "$PACKAGE" rm -f code_cache/store_shots/request
        read -r name themes <<<"$request"
        status_bar
        for theme in ${themes//,/ }; do
          "${a[@]}" shell cmd uimode night "$([ "$theme" = dark ] && echo yes || echo no)" >/dev/null
          sleep "$([ "$theme" = light ] && echo 2 || echo "$THEME_SETTLE")"
          "${a[@]}" exec-out screencap -p >"$shots/$name-$theme.png"
          echo "   $name-$theme"
        done
        if [ "$theme" != light ]; then
          "${a[@]}" shell cmd uimode night no >/dev/null
          sleep "$THEME_SETTLE"
        fi
        "${a[@]}" shell run-as "$PACKAGE" touch code_cache/store_shots/done
      fi
    fi
    sleep 0.5
  done

  finish android "$pid" "$log" "$shots"
  demo exit
}

# ----- Both -----

finish() {
  local kind="$1" pid="$2" log="$3" shots="$4"
  if ! wait "$pid"; then
    # The test photographs the screen it stopped on before it gives up.
    mv "$shots/_failure-light.png" "$OUT/$kind-failure.png" 2>/dev/null || true
    tail -40 "$log" >&2
    echo "== $kind: the screenshot test failed; see $log and $OUT/$kind-failure.png" >&2
    exit 1
  fi
  local shot missing=0
  for shot in "${SHOTS[@]}"; do
    if [ ! -f "$shots/$shot.png" ]; then
      echo "== $kind: STORE_SHOTS names $shot, which the test did not take" >&2
      missing=1
    fi
  done
  [ "$missing" = 0 ] || exit 1
}

# The first $APP_STORE_LIMIT of STORE_SHOTS from $1, numbered, at $3 x $4 into $2.
app_store_set() {
  local from="$1" to="$2" i=0 shot
  rm -rf "$to"
  mkdir -p "$to"
  for shot in "${SHOTS[@]:0:$APP_STORE_LIMIT}"; do
    i=$((i + 1))
    "$WORK/fit" "$from/$shot.png" "$to/$(printf %02d "$i")-$shot.png" "$3" "$4"
  done
}

for kind in "${DEVICES[@]}"; do
  case "$kind" in
    iphone | ipad) capture_ios "$kind" ;;
    android) capture_android ;;
    *) echo "unknown device: $kind" >&2; exit 2 ;;
  esac
done

[ ${#SHOTS[@]} -le $APP_STORE_LIMIT ] ||
  echo "== the App Store takes $APP_STORE_LIMIT a size: ${SHOTS[*]:$APP_STORE_LIMIT} go to F-Droid only"
# fit at a capture's own size only flattens it: App Store Connect takes no alpha.
if [ -d "$OUT/source/iphone" ]; then
  app_store_set "$OUT/source/iphone" "$OUT/app-store/iphone-6.9" 1320 2868
  app_store_set "$OUT/source/iphone" "$OUT/app-store/iphone-6.5" 1242 2688
fi
if [ -d "$OUT/source/ipad" ]; then
  app_store_set "$OUT/source/ipad" "$OUT/app-store/ipad-13" 2064 2752
fi
if [ -d "$OUT/source/android" ]; then
  rm -rf "$OUT/fdroid"
  mkdir -p "$OUT/fdroid"
  i=0
  for shot in "${SHOTS[@]}"; do
    i=$((i + 1))
    cp "$OUT/source/android/$shot.png" "$OUT/fdroid/$(printf %02d "$i").png"
  done
fi

if [ "$UPDATE_FDROID" = 1 ]; then
  [ -d "$OUT/fdroid" ] || {
    echo "no F-Droid set: take it with --device android" >&2
    exit 1
  }
  dest=fastlane/metadata/android/en-US/images/phoneScreenshots
  rm -f "$dest"/*.png
  cp "$OUT"/fdroid/*.png "$dest/"
  echo "== F-Droid: $(ls "$OUT/fdroid" | wc -l | tr -d ' ') screenshots in $dest"
fi

echo "== done: $OUT"
