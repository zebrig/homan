# Quickstart: CoreAudio Lifecycle Hardening Verification

## Preconditions

- Work from the `muesli` development fork.
- Keep SwiftPM artifacts below `muesli/.cache/swiftpm`.
- Do not replace `/Applications/Homan.app` for an experiment.
- Use a named dev lane for any GUI/hardware validation.

## Focused deterministic verification

```bash
cd muesli
swift test \
  --disable-sandbox \
  --disable-automatic-resolution \
  --package-path native/MuesliNative \
  --scratch-path "$PWD/.cache/swiftpm/test" \
  --filter RouteAwareMeetingMicRecorderTests
```

Use fresh repo-local `CLANG_MODULE_CACHE_PATH` and `SWIFTPM_MODULECACHE_OVERRIDE` values if the
ambient module cache is outside the workspace. The existing populated scratch path avoids network
resolution in restricted development sessions.

Then run the adjacent audio suites selected by `tasks.md`.

## Required blocked-start scenario

1. Start recorder A.
2. Configure replacement B so `start()` blocks on a semaphore.
3. Request B and wait until its physical start enters.
4. Deliver 100 alternating desired route IDs, pause/resume the first recorder, and request a handoff
   from a second recorder.
5. Verify no additional factory/prepare/start call occurs and only one lease is unfinished.
6. Release B.
7. Verify B cannot promote if superseded.
8. Verify the latest eligible waiter automatically attempts its current route; a stopped waiter does
   not.

Repeat with the candidate blocked in `prepare()` and cover signal-before-return,
timeout-before-return, late-success, late-failure, and stale-timeout interleavings.

## Hardware experiment

Use a named lane such as:

```bash
cd muesli
./scripts/dev-test.sh --lane A
```

Run the baseline with the environment key absent. For the listener-disabled comparison, set the
dev-lane-only experiment key before launching the named lane, then remove it immediately after the
run:

```bash
launchctl setenv HOMAN_DEV_DISABLE_OUTPUT_TAP_REBUILD 1
./scripts/dev-test.sh --lane A
launchctl unsetenv HOMAN_DEV_DISABLE_OUTPUT_TAP_REBUILD
```

The key is intentionally ignored by owner Homan (`com.zebrig.homan`) and the unnamed dev bundle;
only `com.muesli.dev.a/b/c` can disable the listener.

Before each run, close owner Homan and every other dev lane to avoid hard-coded aggregate UID
collisions. Record the macOS build, Homan commit, lane bundle ID/TCC state, device model/firmware, and
Teams version. The experiment must compare current behavior and listener-disabled behavior for:

- Built-in -> AirPods -> Built-in;
- AirPods disconnect/reconnect;
- a live Teams call with remote speech;
- Teams virtual audio if present;
- rapid A -> B -> C switching;
- repeated start/stop cycles.
- USB and display output when the hardware is available; otherwise mark the row `N/A` and do not
  generalize the result to that route class.

For every transition record:

- output and input route UID;
- tap callback count and maximum callback gap;
- non-zero signal before and after;
- source format before and after;
- Homan thread count;
- CoreAudio context/tap/aggregate observations;
- whether audible output follows the selected device.

Use a fixed known non-zero remote speech source. Run every available transition at least five times
and a separate 50-cycle start/stop/switch soak. Preserve the raw system track for local signal
inspection, but never attach it to telemetry. For each row define the observed baseline p50/p95,
post-switch RMS/non-zero threshold, maximum callback gap, and app scheduling overhead after the
baseline run and freeze them before the listener-disabled run. The experiment may not invent a
universal threshold after seeing only one route.

Do not approve listener removal if any required transition lacks verified non-zero remote audio.
Passing one Mac is an owner-build decision, not proof for all supported hardware/macOS versions; any
production removal requires a separate review and a staged/kill-switch plan.

## Incident log extraction

```bash
log show \
  --predicate 'subsystem == "com.muesli.native" && category == "AudioLifecycle"' \
  --last 1h
```

Lifecycle logs expose operation IDs, duration, phase, ephemeral CoreAudio object IDs, and status.
They do not expose device names, full hardware UIDs, filenames, transcripts, or audio.
Any shared experiment report follows the same rule; a full route UID may appear only in the local,
non-shared hardware worksheet when needed to disambiguate attached devices.
