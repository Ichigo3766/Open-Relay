# Read-aloud header layout

The read-aloud player previously overlaid the model selector. It now occupies
a centered row in the top safe-area bar, below the existing header controls.
Preparing, paused, expanded and failed sessions must leave the header usable.
Closing the player removes its row without changing the header's geometry.

## Focused checks

Run `bash Tests/AudioPlayerHeader/run.sh`. It extracts the production visibility
predicate, checks all input combinations and guards the top-bar placement.
These checks do not replace the UI geometry tests.

## Simulator reproduction

1. Run `python3 -B Tests/AudioPlayerHeader/fixture.py`.
2. In an isolated simulator, connect Open Relay to `http://127.0.0.1:18191`.
   Sign in with `demo@example.test` and any invented password. Never use a
   personal account for these tests or screenshots.
3. Add `AudioHeaderUITests.swift` to an XCUITest runner and run both tests.
   They open the invented chat, invoke Speak, check preparation and centering,
   verify that the close glyph is drawn, expand controls, wait for playback to
   advance beyond zero, pause/resume, open the model picker,
   exercise a controlled HTTP failure and close the player.
4. On the unchanged app, the preparation assertion fails because the player
   overlaps the header. With the fix, all header controls remain accessible
   and keep their original frames. Screenshots are attached to the test results.

The fixture generates a quiet 45-second tone locally; it uses no recording,
provider credentials or real server. It tests playback and layout, not provider
reliability. The HTTP failure is deliberately simulated.
