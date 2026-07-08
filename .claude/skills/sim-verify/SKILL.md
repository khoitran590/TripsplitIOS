---
name: sim-verify
description: After any UI or behavior change to the Tripsplit app, build, launch in the iOS Simulator, drive the changed screen, and screenshot it BEFORE reporting done. Use whenever a change touches SwiftUI views, navigation, layout, or anything the user would see or tap — do not hand back with only a successful xcodebuild.
---

# Simulator verification for Tripsplit

A compiling build is not verification. ~1 in 4 turns in this project's history is the user pasting a screenshot or runtime error that a simulator launch would have caught. Never end a UI-affecting turn on "build succeeded."

## Steps

1. **Build** (as in CLAUDE.md):
   ```sh
   xcodebuild -project Tripsplit.xcodeproj -scheme Tripsplit \
     -destination 'platform=iOS Simulator,name=iPhone 17' build
   ```
   If the destination is missing: `xcrun simctl list devices available` and pick the newest iPhone.

2. **Install + launch** on the simulator:
   ```sh
   xcrun simctl boot "iPhone 17" 2>/dev/null || true
   open -a Simulator
   APP=$(find ~/Library/Developer/Xcode/DerivedData -path '*Build/Products/Debug-iphonesimulator/Tripsplit.app' -newer Tripsplit.xcodeproj -print -quit)
   xcrun simctl install booted "$APP"
   xcrun simctl launch booted $(defaults read "$APP/Info" CFBundleIdentifier)
   ```

3. **Watch for crashes** while exercising the app:
   ```sh
   xcrun simctl spawn booted log stream --predicate 'process == "Tripsplit"' --level error
   ```
   Run in background for ~30s; a launch crash, Auto Layout "Unable to simultaneously satisfy constraints" spew, or main-thread violation shows up here.

4. **Screenshot the changed screen(s)** and actually look at them with Read:
   ```sh
   xcrun simctl io booted screenshot /tmp/claude/sim-verify.png
   ```
   Take one screenshot per screen you changed, in both light and dark mode when the change touches Theme/colors:
   ```sh
   xcrun simctl ui booted appearance dark   # then screenshot again
   ```
   Navigation to deeper screens usually requires a signed-in session; if the sim has one from a previous run, use it. If auth blocks you, screenshot what you can reach and say exactly which screens you could not verify.

5. **Judge the screenshot against the request**, not just "did it render": overlapping elements, truncated text, empty gaps, wrong spacing, elements covering the map/cards, tab bar overlap. These are the exact issues the user historically had to report manually.

## Reporting

End the turn with: what was verified visually (attach/mention screenshot paths), any log errors seen, and explicitly which flows were NOT exercised (e.g. "did not test invite flow — needs a second account").
