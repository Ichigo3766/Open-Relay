Run from the repository root, keeping generated files outside the checkout:

```sh
python3 Tests/StartupOrder/run-tests.py /path/outside/checkout/startup-checks
```

The runner compiles the actual `loadConversations` method and the iPhone/iPad
startup task bodies against invented asynchronous transports. It adapts SwiftUI
value-view captures to a reference test host; it does not substitute the startup
algorithm. No server, credentials, stored chats, or simulator is needed.

The 64 checks cover cached and uncached restoration, empty and unavailable caches,
failed refreshes, missing/deleted last IDs, existing and concurrent navigation, new-chat/channel/folder selections, pending channel routes,
cancellation, replacement account clients, overlapping list loads, and intervening index mutations.
They also verify that each sidebar task still runs once per tested startup invocation.
The focused timings exclude SwiftUI rendering and app launch; native launch
measurements are reported separately in the PR.

Use `--source-root /path/to/another/checkout` to run the same reproduction against
the unmodified source. At `3e721e3`, 20 checks fail; the candidate passes all 64.
