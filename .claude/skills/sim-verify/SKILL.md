---
name: sim-verify
description: Build, launch, drive, and screenshot the Tripsplit app in the iOS Simulator. Use ONLY when the user explicitly asks to verify/run/screenshot in the simulator, or for large risky UI changes (new screens, navigation rework, theme overhauls). For routine features and small UI tweaks, a clean error-free xcodebuild is enough — the user runs the app themselves.
---

# Simulator verification for Tripsplit

## When to use this skill

The user's standing preference: **do not run the simulator for every change.** For small features and improvements, verify with a clean build (`xcodebuild ... build` with zero errors) and hand back — the user runs the app themselves.

Run the full simulator flow below only when:
- the user explicitly asks ("run it", "screenshot it", "verify in the sim"), or
- the change is large and visually risky: a brand-new screen, navigation restructuring, or app-wide theme/layout changes.

## Steps

1. **Build** (as in CLAUDE.md):
   ```sh
   xcodebuild -project Tripsplit.xcodeproj -scheme Tripsplit \
     -destination 'platform=iOS Simulator,name=iPhone 17' build
   ```
   If the destination is missing: `xcrun simctl list devices available` and pick the newest iPhone.

   **Stale-build trap:** incremental builds can silently ship old code. Before trusting what you see on screen, check the app's `debug.dylib` mtime is newer than your edits, or clean-build.

2. **Install + launch** on the simulator:
   ```sh
   xcrun simctl boot "iPhone 17" 2>/dev/null || true
   open -a Simulator
   APP=$(find ~/Library/Developer/Xcode/DerivedData -path '*Build/Products/Debug-iphonesimulator/Tripsplit.app' -newer Tripsplit.xcodeproj -print -quit)
   xcrun simctl install booted "$APP"
   xcrun simctl launch booted $(defaults read "$APP/Info" CFBundleIdentifier)
   ```

3. **Watch for crashes** while exercising the app (run in background ~30s):
   ```sh
   xcrun simctl spawn booted log stream --predicate 'process == "Tripsplit"' --level error
   ```
   Launch crashes, Auto Layout "Unable to simultaneously satisfy constraints" spew, and main-thread violations show up here.

4. **Drive the changed screen.** Use System Events accessibility-element clicks (not screen coordinates or cliclick). A signed-in session is usually required for deeper screens; the test account is `khoitran590+onboardtest@gmail.com`. If auth blocks you, screenshot what you can reach and say exactly which screens you could not verify.

5. **Screenshot and actually look** (with Read):
   ```sh
   xcrun simctl io booted screenshot /tmp/claude/sim-verify.png
   ```
   One screenshot per changed screen; add dark mode when the change touches Theme/colors:
   ```sh
   xcrun simctl ui booted appearance dark   # then screenshot again
   ```

6. **Judge against the request**, not just "did it render": overlapping elements, truncated text, empty gaps, wrong spacing, tab-bar overlap — the exact issues the user historically reported manually.

## Reporting

End the turn with: what was verified visually (screenshot paths), any log errors seen, and explicitly which flows were NOT exercised (e.g. "did not test invite flow — needs a second account").
