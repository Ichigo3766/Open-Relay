# Calendar invitation responses

Baseline: Open Relay 6.0, `4151a735512d5d6dbc9fd1962fa806517a0d4ea7`.
Contract: Open WebUI `8bd8b4fac5e059578ac0c74b3c18d11139f88b7d`.

Relay discards the native event's `attendees` array, so the signed-in attendee
cannot see or change their response. The new event-detail row calls the existing
authenticated `POST /api/v1/calendars/events/{id}/rsvp` route. It does not replace
the event, calendar, attendee list, recurrence rule, or other metadata.

The server owns RSVP authorization and applies the response only to the signed-in
attendee. The client checks membership, serializes writes per event, and changes
the displayed status only after a successful matching acknowledgement. An RSVP
applies to the whole recurring series, which is stated in the UI. Cancelled and
system events do not offer the control. Unknown saved statuses remain readable.

This exposes a native server capability, not a claim that the current web event
modal already displays an RSVP picker. Adding/removing invitees is separate.

## Focused checks

```sh
python3 Tests/CalendarRSVP/run.py --baseline  # expected failure: attendee data lost
python3 Tests/CalendarRSVP/run.py
python3 Tests/CalendarRSVP/run.py --actions
```

These compile the actual production model and RSVP methods, with transport and
unrelated SwiftUI color handling stubbed. Coverage includes missing/null attendee
lists, unknown statuses, all four native response values, exact route/body,
recurring instances, unrelated attendees/events, malformed acknowledgements,
request failures, manual retry, overlapping taps, cancellation and account scope.
The RSVP API uses the existing single-attempt transport instead of the JSON
helper's automatic mutation retries; global networking is unchanged.

## Full-app simulator check

Run `fixture.py` with Python and aiohttp, using an isolated app/simulator signed in
to `http://127.0.0.1:18191` with invented credentials. The fixture uses only newly
invented invitations and validates the synthetic bearer token. It has no upstream
connection and cannot read a personal library.

Generate the UI test project with `xcodegen generate` in this directory. Run the
`CalendarRSVP` scheme against an installed app build, supplying a simulator ID and
external `-derivedDataPath` / `-resultBundlePath`. Run `testBefore` only on the
baseline; run the three other tests on the fixed build. The tests cover all choices,
relaunch, the series route, another attendee remaining unchanged, no control for
a non-attendee, failure/retry, pending disablement, malformed success bodies, and
the largest accessibility text size.

Only reviewed screenshots of this synthetic fixture belong in `Screenshots`.
Never commit app containers, result bundles, raw logs, or any instance data.

## Verified results

- Baseline model reproduction fails; the fixed model passes.
- All 31 focused production-code checks pass.
- Full Release simulator build passes.
- All three full-app UI tests pass on iOS 26.5, including the failed-save/manual
  retry request count (two writes), relaunch, all response choices, and large text.
- Before/after, menu, and dark-mode screenshots use only the invented fixture.

These are isolated client/HTTP-fixture tests, not tests of a production calendar
or live multi-user delivery. Open WebUI's server authorization was source-reviewed;
the real app's authentication header and request contract were runtime-tested.
