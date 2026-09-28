# Short-paragraph read-aloud look-ahead

Baseline: Open Relay 6.0, `4151a735512d5d6dbc9fd1962fa806517a0d4ea7`.

The completed-message server player already fetches ahead, but each speech
request waits for the previous one to finish. A short paragraph can run out
before the request after it completes.

The first chunk still starts alone. Afterward, when the next chunk is at most
160 characters, one additional request may run alongside it. This character
limit is a small-text heuristic, not a prediction of speaking duration. Longer
chunks remain serial. There are never more than two generation requests in
flight per active producer, and responses are committed in text order.

Existing disk-backed buffering, whole-message preparation, seeking, playback
rate, manual retry, and player UI are preserved. This does not change voice-call
TTS, system speech, on-device synthesis, server settings, or global networking.
It adds no timer or startup buffer. A server that serializes synthesis itself,
or cannot generate audio fast enough, can still cause gaps.

## Native player tests

The small test host compiles the production `ReadAloudPlayer.swift`, not a
reimplementation. It uses freshly generated PCM WAV data and mocked synthesis.
No accounts, real recordings, or provider credentials are needed.

```sh
cd Tests/ReadAloudPrefetch
xcodegen generate
xcodebuild -project ReadAloudPrefetch.xcodeproj -scheme ReadAloudPrefetch \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -derivedDataPath /path/to/build-output \
  -resultBundlePath /path/to/results.xcresult \
  -parallel-testing-enabled NO -collect-test-diagnostics never test
```

The suite covers bounded concurrency, threshold boundaries (including Unicode),
single/long chunks, ordering, retry, cancellation of an in-flight sibling,
replacing a session, pause/seek, playback rate, interruptions, corrupt audio,
queue underruns, completion, and temporary-file cleanup.

For before/after measurements, run `testSyntheticGapBenchmark` three times with
`-test-iterations 3`. Each of three synthesis requests takes one second; the
audio durations are 1.25, 0.15, and 1.25 seconds. The test samples the real
player's playback state every 10 ms after playback first starts and totals time
spent waiting while playback is requested. It prints only synthetic timings.
The stall assertion and overlapping-request assertion fail on the baseline.
These are simulator results, not an acoustic measurement or provider benchmark.

### Measured comparison (iOS 26.5)

Three repeated runs per version, after separate baseline/fixed assertion runs:

| Measurement | Baseline | With short-chunk look-ahead |
| --- | ---: | ---: |
| First playback, median | 1.033 s | 1.040 s |
| First playback, range | 1.029–1.106 s | 1.026–1.108 s |
| Observed stall, median | 0.499 s | 0.000 s |
| Observed stall, range | 0.456–0.511 s | 0.000–0.000 s |
| Peak generation requests | 1 | 2 |

All 25 focused player tests pass with the change. The Release app build passes.
The full-app HTTP/UI test also passes: three authenticated requests, overlapping
look-ahead, advancing playback, pause/resume, and Close.
Zero here means no waiting samples in this fixture; it does not guarantee
gapless playback for every server, connection, or audio format.

## Full-app HTTP check

Start `python3 Tests/ReadAloudPrefetch/fixture.py` from the repository root.
In an isolated app/simulator, sign in to `http://127.0.0.1:18191` with invented
values, then install the normal application build. Never use a personal library.

Run the `AppPrefetch` scheme in the generated project. It opens the synthetic
chat, presses Speak with paragraph splitting, verifies progress and pause/resume,
closes the player, and checks server timestamps. The fixture accepts only its
three invented input strings and the synthetic bearer token. It verifies that
the third request starts before the second finishes, but not before the first
has completed. No real provider is called.

Only reviewed source, invented fixture data, and aggregate measurements belong
in this test directory. Do not commit result bundles, recordings, app data,
credentials, or diagnostic logs.
