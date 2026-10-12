# Synthetic regression checks

Run on macOS with Python 3 and the Xcode command-line tools. Inputs are freshly invented; the runner never reads app containers, credentials, server configuration, or existing chats. Generated sources, binaries, and module caches must stay outside the checkout.

```sh
python3 Tests/TerminalDiscovery/run-tests.py /external/scratch
/external/scratch/checks --benchmark
/external/scratch/checks --benchmark-socket
/external/scratch/checks --benchmark-params
```

The runner extracts the production terminal-discovery method, its startup call, the background connection startup, and default-parameter discovery/startup into an observable model with gated terminal, socket, and parameter transports. Checks cover release during suspended requests, completion after release, visible selection/cache updates, removed terminals, failure, missing managers, parameter cache/context updates, failure, awaiting completion, and cancellation propagation. `--source` accepts a prior ChatViewModel.swift for a failing control.

Each benchmark leaves one of six independent 16 MiB synthetic histories visible while requests are suspended. Report retained models/payload bytes separately from RSS, which also includes allocator overhead. It is a component fixture, not a whole-client memory measurement.
