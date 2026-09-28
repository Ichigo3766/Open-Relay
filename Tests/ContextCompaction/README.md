# Native conversation context controls

Baseline: Open Relay 6.0, `4151a735512d5d6dbc9fd1962fa806517a0d4ea7`.
Server contract: Open WebUI `8bd8b4fac5e059578ac0c74b3c18d11139f88b7d`.

These controls use `context_usage` from the authenticated chat response and
the native `POST /api/v1/chats/{id}/compact` endpoint. The progress indicator
represents the server's estimated usage against its **compaction threshold**,
not a measured model context-window percentage. The section is absent when
the server returns no usage, including when compaction is disabled.

The same change preserves `contextSummary` checkpoints in history round trips
(and accepts the legacy `context_summary` spelling). The baseline drops this
field. That is a verified client round-trip loss, not an end-to-end claim that
every server storage path deletes its copy of the checkpoint.

## Focused tests

On macOS with Swift: `python3 Tests/ContextCompaction/run.py`.
`--baseline` compiles the original history source and intentionally fails the
checkpoint-preservation assertion. No Open WebUI modules are imported or run.

The harness uses actual history/message models, context decoding, API method,
and view-model action methods, with mocked network/cache/manager collaborators.
It checks 8 checkpoint cases and 36 usage/API/action cases: malformed values,
native URL/model/timeout, updated usage/checkpoints, single-flight execution,
no automatic resubmission, refresh-only recovery, failed refresh, streaming and
temporary-chat guards, late responses after chat/account changes, and server
no-op/error responses.

## Synthetic simulator fixture

Run `fixture.py` with `aiohttp` in an isolated test environment. Connect an
isolated simulator app to `http://127.0.0.1:18191` using invented credentials.
The fixture contains only a freshly invented paper-craft conversation and
does not call a model or a real server.

Generate the standalone project with `xcodegen generate --spec project.yml`.
Run `ContextUITests/testBefore` against the baseline app, then
`ContextUITests/testContext` against the changed app. Tests exercise Controls,
confirmation cancellation, successful compaction, refreshed usage, HTTP 503,
refresh without a second POST, reopening, and a server with usage disabled.

The Release iOS simulator build and both UI tests passed on an iPhone simulator
running iOS 26.5. Screenshots were captured from those test runs and visually
reviewed, including PNG metadata. The fixture validates the client contract;
it does not measure the quality of a real model-generated summary.

## Safety and scope

Compaction is explicit, single-attempt, disabled while streaming, and uses a
scoped 300-second timeout. Sending/editing/regenerating is held while the
request or its follow-up refresh is unresolved. A failed or lost response
offers a GET refresh, not automatic repeat summarization. This does not promise
exactly-once server execution. Original messages stay visible; the server owns
summary generation. No custom summarizer or global networking retry changes.

Only invented fixture data and reviewed synthetic screenshots belong in this
directory. No private chats, server configuration, credentials or logs.
