The checks compile the production streaming deceleration guard unchanged with freshly invented geometry values. They cover bottom, near-bottom, threshold, earlier-content, overscroll, short-content, nonstreaming, and already-paused cases. They test the pause decision, not a complete UIKit gesture or the rest of the scroll observer.

Run `python3 Tests/DecelerationDistance/run-regression-checks.py /path/to/external/scratch`. Pass `--source /path/to/earlier/ChatDetailView.swift` to reproduce the four false pause decisions on v6.3.4. Generated sources and binaries stay outside the checkout.
