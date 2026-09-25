# Synthetic before/after video

Historical capture notes for the animation-free implementation. The current
three-stage typewriter comparison is described in [EFFICIENCY.md](../EFFICIENCY.md#video).

Local exports: `normal-speed.mp4` (21.5 seconds) and `quarter-speed.mp4`
(86 seconds). Both show the same three cases side by side. Media remains outside
version control and has not been uploaded.

The app builds and simulator match [the native benchmark methodology](../BENCHMARKS.md).
The candidate app is the implementation at `30d19ca`; this recording pass changes
only the test harness and documentation, not application code.

| Case | Response characters | Planned delivery | Maximum emission lateness, original / candidate |
| --- | ---: | --- | ---: |
| Slow answer following reasoning | 196 | 20 characters every 500 ms | 4.60 / 5.56 ms |
| Ordered list, tilde fence, Unicode, math and link | 1,812 | 20 characters every 50 ms | 34.12 / 6.75 ms |
| Long prose | 16,788 | 200 characters every 30 ms | 3.14 / 7.82 ms |

Response hashes and planned chunk schedules match between builds. Actual sending
is not perfectly punctual; the table reports the measured worst delay. These are
qualitative recordings, not additional FPS or physical-device latency benchmarks.

## Capture and editing

- Only freshly invented fixture content is used. No production account, service,
  chat, API key or real model response is involved.
- Both Release builds pass `testVideoComparison`, including an explicit check
  that the reasoning stream remains active after eight seconds, followed by
  completion checks for all three cases. Two Python fixture tests verify the
  task-registry contract, replay payloads, final content and absolute deadlines.
- The ready/running cue and its two-second prelude belong to the fixture only;
  no waiting is added to the application.
- Clips align on the first visible `Replay running` cue, not first answer text.
  Alignment is approximate to a captured/exported frame. Both sides use identical
  cropping, scaling and speed. The OS status bar and all setup screens are omitted.
- Simulator video is variable-frame-rate. Normalize through AVFoundation, verify
  sample frames against native playback, then use single-threaded decoding when
  assembling these clips. In this environment, direct multithreaded FFmpeg
  decoding produced incorrect frames/timing; those conversions were discarded.
- Export is H.264, 1000×1220, 30 fps. Quarter speed holds each normal-speed frame
  four times as long. There is no motion interpolation or generated in-between
  content. A 30-fps export does not imply the app or simulator ran at 30 fps.
- Review the normal-speed frames/contact sheets and the quarter-speed rendering.
  The normal export contains 645 frames; the slow export contains 2,580 repeated
  frames with a different speed caption. Strip source metadata and audio; the
  exports contain one video track and generic codec/container tags only.

The visible differences include earlier answer delivery, stable ordered-list
numbering during arrival, and completion-layout differences. New reasoning
metadata still legitimately inserts a disclosure row at completion. The clips
do not establish that every possible source of scrolling judder is eliminated.

Earlier mock runs could finish reasoning prematurely because their task-registry
response used an unsupported shape. They are not used in these exports; see the
benchmark report's correction. The separate native timing results are unaffected.
