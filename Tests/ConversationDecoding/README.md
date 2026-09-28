# Reuse validated conversation JSON

Run `TMPDIR=<scratch> bash Tests/ConversationDecoding/run.sh candidate` and repeat
with `baseline`. The runner compiles actual cache and API response handling,
injecting only disposable storage and a JSON decode counter. Networking and final
model construction are controlled substitutes; no server or account is used.

Checks cover cold/recent/cached/304 reads, scope separation, authorization errors,
invalid JSON, wrong IDs, absent chat objects, unfinished messages, no-store,
corrupt recent disk entries, clear-during-revalidation, concurrent callers,
cancelled waiters, account switches during requests, and account-wide 401
invalidation. Candidate reads parse
the JSON tree once; baseline paths parse it twice (three times for a 304).

Add `--benchmark` for 15 reads per synthetic history size. This measures cache
validation and JSON decoding, not the rest of model construction or UI latency.
Run baseline/candidate pairs on an otherwise idle machine.
