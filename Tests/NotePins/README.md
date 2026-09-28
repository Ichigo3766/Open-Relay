# Native note pins

Based on Open Relay 6.0 (`4151a73`), Open WebUI `8bd8b4f`.

`python3 Tests/NotePins/run.py` compiles the production parser, pin API, manager,
and view-model method with a synthetic transport/cache. All 19 checks pass:
server pin decoding, authoritative responses, malformed/error responses, local
content preservation, local-only and disconnected operation, duplicate taps,
partial caches, and search-row updates. `--baseline` fails because the native
`is_pinned` value is discarded.

The request uses the existing single-attempt raw transport: pin is a toggle, so
automatically retrying an uncertain response could undo a successful operation.
After a network error, refresh Notes before trying again; the server may have
received the operation even when its response did not arrive.

For app checks, start `fixture.py` and connect only an isolated simulator to
`http://127.0.0.1:18191`, using the invented login `demo@example.test` / `synthetic`.
Generate `project.yml` with XcodeGen and run the `NotePins` scheme:

- `testBefore`: a server-pinned note appears without a Pinned section.
- `testPinRoundTrip`: native pin display, unpin, reopen, pin, and an explicit
  server failure. Check the request count and unchanged display after failure.

Both simulator tests passed on iOS 26.5 using 6.0-based builds. The final Release
app build passed. Before/after screenshots are in `Screenshots/`.

New local-only notes are marked explicitly so their pins stay local. Existing
server notes are not silently treated as local when disconnected. This does not
add offline pin queuing or migrate old local notes lacking that marker.

All content is invented. No private instance, notes, chats, credentials, or logs
are part of the fixture or published assets.
