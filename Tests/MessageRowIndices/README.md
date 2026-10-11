These native SwiftUI checks compile the production `messagesList` body unchanged with observable synthetic models and lightweight row slots. They inspect the indices and draw decisions delivered to those slots; bubble rendering and scroll geometry are outside this fixture.

Run `python3 Tests/MessageRowIndices/generate-regression-project.py /path/to/external/scratch`, then build and test the generated `Regression` scheme on an available iOS simulator. XcodeGen is required. Keep generated projects, build products, results, and media outside the checkout.

To reproduce on an earlier revision, pass `--source /path/to/earlier/ChatDetailView.swift`. Middle replacement and reorder fail on v6.3.4. The suite also covers insertion, deletion, assistant runs, leading assistants, empty histories, and streaming/editing overrides. All message identifiers are freshly invented.

`run-bookkeeping-benchmark.py` measures 500 grouping/index-decision evaluations over 6,000 invented messages after 20 warm-up evaluations. It prints wall time, process CPU time, end RSS, and a checksum. Compare alternating fresh processes with `--source` for the earlier revision. The old cache write is immediate in this component fixture; SwiftUI rendering, asynchronous invalidation, gestures, and navigation are excluded.
