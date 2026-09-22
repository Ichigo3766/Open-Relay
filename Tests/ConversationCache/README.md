# Persisted conversations and incremental sidebar refresh

Run on macOS with Xcode command-line tools:

```sh
python3 Tests/ConversationCache/run.py
```

The five suites compile the real cache and sidebar index, API fetch methods, sidebar pagination methods, chat loading/write guards, and complete `NetworkManager`. Dependencies use synthetic fixtures; the transport suite intercepts `URLSession` requests with `URLProtocol`. The runner does not contact a server, use application credentials, or read an existing cache. Each executable uses a disposable directory and isolated preferences.

Coverage includes persistence and recent navigation reuse; full-response replacement and conditional 304 reuse; servers without validators; server/session/header isolation; corruption, expiration, access denial and offline failure; unfinished responses; cache directives; shared in-flight requests; mutation, clear and background-decoding races; global LRU eviction, oversized responses and disabling the cache. Sidebar checks cover restoration before the first response, updates spanning multiple pages, overlap stopping, full reconciliation, malformed rows, partial failures, local edits during pagination and account switching. Chat loading checks cover read-only previews and write guards, background validation, failed validation, deletion and model-catalog loading. Transport checks exercise conditional/authentication/custom headers, base paths, invalidation before and after a pending write, token rotation and HTTP 401.

Repeat each suite and check for data races:

```sh
python3 Tests/ConversationCache/run.py --repeat 20
python3 Tests/ConversationCache/run.py --sanitize-thread --repeat 5
```

Use `--only Cache Sidebar API Load Network` with any subset to run individual suites.

To reproduce the previous repeated-download behavior using the original API method:

```sh
python3 Tests/ConversationCache/run.py --only API --baseline-ref a5c0cfa014c92b4875b7ccb2a64562205b258eb8
```

The navigation assertion fails at that revision: two consecutive reads transfer two synthetic 3 MB bodies. The current navigation path transfers one. This measures request count and response bytes with a synthetic transport, not device latency.

## Behavior and limits

- Cached conversation bodies and sidebar summaries share a 50 MB default budget. Storage settings offer Off, 25, 50, 100 and 250 MB, plus clearing. Least recently accessed files are evicted first; saved entries expire after seven days. Files are excluded from backup and use iOS file protection.
- Cache filenames hash the server URL, authenticated session and custom headers. Tokens are not stored in records. A different session cannot reuse another session's entries; logout and existing account-data cleanup clear saved copies.
- Navigation can reuse a successful response for up to 30 seconds. Server cache directives can shorten that window. Socket events, writes and changed sidebar metadata invalidate saved bodies. Streaming/unfinished responses are not saved.
- Older saved chats appear as read-only previews while revalidating. Offline failures retain the preview. Access denial or deletion removes it. Editing and sending are unavailable from stale previews; this is not an offline write queue.
- Revalidation uses `If-None-Match` only when the server supplied an ETag. Without a validator, it fetches the full conversation. It does not assume that `updated_at` proves message content unchanged and does not implement a message-delta API.
- The sidebar scans until two consecutive pages match previously known summaries. Pull-to-refresh and refreshes due six hours after the last complete scan reconcile older changes, deletion, archive and folder moves. Initial cold loads still fetch all pages, with page one displayed first and later pages fetched in batches of five. Failed pages never count as the end of the list, and pending refreshes cannot overwrite local edits. The server's page API is not an atomic snapshot; changes during pagination converge on subsequent refresh/reconciliation.

Validation does not include physical-device timing or live-instance testing. UI review should cover Settings → Storage → Conversation Cache, reopening a saved chat while offline, Retry, clearing, and switching accounts using synthetic test accounts.
