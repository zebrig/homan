#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$REPO_ROOT/native/MuesliNative/Tests"
HAL_TEST="$TEST_ROOT/MuesliTests/AudioGraphExceptionBridgeTests.swift"

reject_pattern() {
  local pattern="$1"
  local message="$2"
  if rg -n "$pattern" "$TEST_ROOT"; then
    echo "test-isolation failure: $message" >&2
    exit 1
  fi
}

reject_pattern 'ChatGPTAuthManager\.shared' 'tests must inject ChatGPTAuthManager'
reject_pattern 'NSPasteboard\.general' 'tests must use named pasteboards'
reject_pattern 'CGEvent\(' 'tests must inject an event sink'
reject_pattern '\.post\(tap:' 'tests must not post HID events'
reject_pattern 'NSWorkspace\.shared\.open' 'tests must not open OAuth or external UI'
reject_pattern 'SystemSoundPlayer\.' 'tests must not call the system sound player'
reject_pattern 'AudioServicesPlaySystemSound' 'tests must not play system sounds'
reject_pattern 'RouteAwareDictationRecorder\(\)' 'tests must inject both route-aware child recorders'
reject_pattern 'AppScopedDictationRecorder\(\)' 'tests must inject a streaming recorder'
reject_pattern 'EKEventStore\(' 'unit tests must use pure calendar occurrence inputs'
reject_pattern 'UserDefaults\.standard' 'unit tests must use an isolated defaults suite'
reject_pattern 'pasteForTesting' 'clipboard tests must exercise the production paste implementation'

if rg -n 'SoundController\.' "$TEST_ROOT" | rg -v 'enabled: false'; then
  echo 'test-isolation failure: sound tests may exercise only production disabled branches' >&2
  exit 1
fi

if rg -n 'PasteController\.typeText' "$TEST_ROOT" | rg -v 'PasteController\.typeText\(""\)'; then
  echo 'test-isolation failure: typeText tests must not post non-empty keyboard input' >&2
  exit 1
fi

if rg -n 'AVAudioEngine\(\)' "$TEST_ROOT" --glob '!AudioGraphExceptionBridgeTests.swift'; then
  echo 'test-isolation failure: AVAudioEngine is allowed only in the opt-in HAL suite' >&2
  exit 1
fi

if ! rg -q '^#if HOMAN_HARDWARE_TESTS$' "$HAL_TEST"; then
  echo 'test-isolation failure: HAL exception tests are not opt-in guarded' >&2
  exit 1
fi

ROUTE_TEST="$TEST_ROOT/MuesliTests/DictationAudioRouteControllerTests.swift"
route_constructions="$(rg -o 'DictationAudioRouteController\(' "$ROUTE_TEST" | wc -l | tr -d ' ')"
fake_inspectors="$(rg -o 'inspector: inspector' "$ROUTE_TEST" | wc -l | tr -d ' ')"
disabled_listeners="$(rg -o 'observesDefaultOutputChanges: false' "$ROUTE_TEST" | wc -l | tr -d ' ')"
if [[ "$route_constructions" != "$fake_inspectors" ||
      "$route_constructions" != "$disabled_listeners" ]]; then
  echo 'test-isolation failure: CoreAudio route tests must use a fake inspector with listeners disabled' >&2
  exit 1
fi

indicator_constructions="$(rg -o 'FloatingIndicatorController\(' "$TEST_ROOT" | wc -l | tr -d ' ')"
disabled_indicators="$(rg -o 'uiEnabled: false' "$TEST_ROOT" | wc -l | tr -d ' ')"
if [[ "$indicator_constructions" != "$disabled_indicators" ]]; then
  echo 'test-isolation failure: every floating indicator test construction must pass uiEnabled: false' >&2
  exit 1
fi

controller_constructions="$(rg -o 'MuesliController\(' "$TEST_ROOT" | wc -l | tr -d ' ')"
side_effect_guards="$(rg -o 'runtimeSideEffectsEnabled: false' "$TEST_ROOT" | wc -l | tr -d ' ')"
inert_duckers="$(rg -o 'audioDuckingController: InertAudioDuckingController\(\)' "$TEST_ROOT" | wc -l | tr -d ' ')"
inert_routes="$(rg -o 'dictationAudioRoutingController: InertDictationAudioRouteController\(\)' "$TEST_ROOT" | wc -l | tr -d ' ')"
nil_calendars="$(rg -o 'calendarMonitor: nil' "$TEST_ROOT" | wc -l | tr -d ' ')"
nil_meeting_monitors="$(rg -o 'meetingMonitor: nil' "$TEST_ROOT" | wc -l | tr -d ' ')"
nil_tour_stores="$(rg -o 'featureTourStore: nil' "$TEST_ROOT" | wc -l | tr -d ' ')"
if [[ "$controller_constructions" != "$side_effect_guards" ||
      "$controller_constructions" != "$inert_duckers" ||
      "$controller_constructions" != "$inert_routes" ||
      "$controller_constructions" != "$nil_calendars" ||
      "$controller_constructions" != "$nil_meeting_monitors" ||
      "$controller_constructions" != "$nil_tour_stores" ]]; then
  echo "test-isolation failure: every MuesliController test construction must select the full inert capability set" >&2
  exit 1
fi

CONTROLLER_SOURCE="$REPO_ROOT/native/MuesliNative/Sources/MuesliNativeApp/MuesliController.swift"
if ! rg -q 'runtimeSideEffectsEnabled: Bool = true' "$CONTROLLER_SOURCE" ||
   ! rg -q 'uiEnabled: runtimeSideEffectsEnabled' "$CONTROLLER_SOURCE"; then
  echo 'test-isolation failure: controller test isolation must be explicit and production-default-safe' >&2
  exit 1
fi

if ! rg -Uq 'func start\(\) \{\n        guard runtimeSideEffectsEnabled else \{ return \}' \
    "$CONTROLLER_SOURCE" ||
   ! rg -Uq 'func shutdown\(\) \{\n        guard runtimeSideEffectsEnabled else \{\n            shutdownIsolatedRuntime\(\)\n            return\n        \}' \
    "$CONTROLLER_SOURCE" ||
   ! rg -q 'usesInertRuntimeDependenciesForTesting' "$CONTROLLER_SOURCE" ||
   ! rg -q 'final class InertDictationAudioRecorder' \
    "$REPO_ROOT/native/MuesliNative/Sources/MuesliNativeApp/DictationAudioSessionManager.swift"; then
  echo 'test-isolation failure: controller lifecycle or recorder capability boundary is missing' >&2
    exit 1
fi

ROUTE_RECORDER_SOURCE="$REPO_ROOT/native/MuesliNative/Sources/MuesliNativeApp/RouteAwareDictationRecorder.swift"
if [[ "$(rg -o 'AppIdentity\.isRunningTests' "$ROUTE_RECORDER_SOURCE" | wc -l | tr -d ' ')" != "2" ]] ||
   ! rg -q 'usesInertChildrenForTesting' "$ROUTE_RECORDER_SOURCE"; then
  echo 'test-isolation failure: default controller recorders are not inert in test processes' >&2
  exit 1
fi

AUDIO_SESSION_SOURCE="$REPO_ROOT/native/MuesliNative/Sources/MuesliNativeApp/DictationAudioSessionManager.swift"
if ! rg -Uq 'mediaPlaybackController: MediaPlaybackManaging = AppIdentity\.isRunningTests\n            \? InertMediaPlaybackController\(\)\n            : MediaPlaybackController\(\)' \
    "$AUDIO_SESSION_SOURCE" ||
   ! rg -q 'usesInertMediaPlaybackForTesting' "$AUDIO_SESSION_SOURCE"; then
  echo 'test-isolation failure: controller audio sessions may construct system media control in tests' >&2
  exit 1
fi

FLOATING_SOURCE="$REPO_ROOT/native/MuesliNative/Sources/MuesliNativeApp/FloatingIndicatorController.swift"
if ! rg -Uq 'private func createPanel\(config: AppConfig\) \{\n        guard uiEnabled else \{ return \}' "$FLOATING_SOURCE" ||
   ! rg -q 'hasActiveUIForTesting' "$FLOATING_SOURCE" ||
   ! rg -q 'disabled indicator never creates panels, spinners, or waveform timers' "$TEST_ROOT"; then
  echo 'test-isolation failure: disabled floating indicators lack a central UI capability boundary' >&2
  exit 1
fi

QOL_TEST="$TEST_ROOT/MuesliTests/QoLTests.swift"
if rg -q 'NSPanel\(|InteractiveFloatingPanel\(' "$QOL_TEST" &&
   ! rg -q '^#if HOMAN_UI_TESTS$' "$QOL_TEST"; then
  echo 'test-isolation failure: AppKit panel tests must be opt-in guarded' >&2
  exit 1
fi

if ! rg -q 'allowLegacyKeychainMutation: !AppIdentity\.isRunningTests' \
  "$REPO_ROOT/native/MuesliNative/Sources/MuesliNativeApp/ChatGPTAuthManager.swift"; then
  echo 'test-isolation failure: shared auth lacks the test-mode Keychain mutation guard' >&2
  exit 1
fi

if ! rg -q 'loadCredentials: !AppIdentity\.isRunningTests' \
  "$REPO_ROOT/native/MuesliNative/Sources/MuesliNativeApp/GoogleCalendarAuthManager.swift"; then
  echo 'test-isolation failure: shared Google auth may read developer credentials during tests' >&2
  exit 1
fi

echo 'test-isolation static gate: PASS'
