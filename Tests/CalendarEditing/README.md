# Calendar event editing

Baseline: Open Relay 6.0, `4151a735512d5d6dbc9fd1962fa806517a0d4ea7`.
Contract reviewed: Open WebUI `8bd8b4fac5e059578ac0c74b3c18d11139f88b7d`,
`routers/calendar.py`, `models/calendar.py`, and `CalendarEventModal.svelte`.

## Focused checks

Run `python3 Tests/CalendarEditing/run.py` with the Swift compiler available.
The 29 checks compile the actual event draft, model, reminder label, API methods,
and save action against isolated networking stubs. They cover native routes and
nanosecond timestamps; null clears; all-day dates; required/range validation;
recurrence and disabled reminders; omission of unsupported metadata; propagated
write failures; account changes; and successful saves followed by refresh failure.
Recurring edits fetch the base event by ID, not a displayed instance's date. The
selected occurrence remains selected after the refreshed series arrives.

## Simulator reproduction

Use an isolated simulator and build the app normally. Install `aiohttp` in a
test environment, then run `python3 Tests/CalendarEditing/fixture.py`. This
loopback-only fixture supplies newly invented calendar data, accepts demo login,
records mutation bodies, and can fail event fetches or saves. It never connects
to an actual server or imports its code.

Sign the isolated app into `http://127.0.0.1:18191` with `demo@example.test` and
a synthetic password. Run `xcodegen generate` in this test directory. Use the
generated `CalendarEditing` scheme with an available iPhone simulator and
ad-hoc-sign its test runner (`CODE_SIGN_IDENTITY=-`). Keep DerivedData and result
bundles outside the checkout.

- On the unmodified calendar path, run `testBefore`: there is no Edit action;
  a failed creation dismisses the form without creating an event.
- On the changed app, skip `testBefore` and run the other cases:
  - `testEditSeries`: failed fetch, retry, custom recurrence preserved, failed
    save retains the draft, retry succeeds without shifting the series start
    or overwriting unrelated metadata/attendees.
  - `testCreateRetry`: weekly recurrence, failed save retains draft, retry
    creates exactly one event.
  - `testCancel`: dark-mode native editor; cancelling changes sends no write.

Full Release simulator builds passed. The before case and all three changed
cases passed on iOS 26.5. The baseline capture used another 6.0-based build with
an unchanged calendar implementation. Screenshots contain only this fixture's
synthetic data; raw result bundles and diagnostic logs are not included.

## Scope

The editor supports title/calendar, dates, all-day events, recurrence presets
and custom RRULE, reminder, location, and description. Recurring edits affect the
whole series and say so in the form. Custom recurrence validation/expansion and
authorization remain server responsibilities; the fixture verifies wire behavior,
not the server's recurrence engine. Attendee management, calendar management, and
existing deletion behavior are not changed. Omitted server fields are preserved
by the native update contract; concurrent edits to the same submitted fields
remain last-writer-wins.
