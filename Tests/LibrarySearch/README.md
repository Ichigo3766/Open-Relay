# Library search regression checks

All fixture accounts, messages, documents, and folders are freshly invented. The
fixture listens only on loopback. Do not point these UI tests at a real library.

## Model and API checks

From the repository root, with the Xcode command-line tools selected:

```sh
SEARCH_QA=$(mktemp -d /tmp/relay-search-tests.XXXXXX)
xcrun swiftc -parse-as-library -default-isolation MainActor \
  -strict-concurrency=complete -warnings-as-errors \
  'Open UI/Features/Chat/ViewModels/LibrarySearchModel.swift' \
  'Open UI/Core/Networking/APIClient+LibrarySearch.swift' \
  Tests/LibrarySearch/ModelTests.swift -o "$SEARCH_QA/model-tests"
"$SEARCH_QA/model-tests"
```

This compiles the production search model and API extension with a minimal
transport double. It checks body-only matches, response shapes, pagination,
deduplication, Unicode snippets, query encoding, document-content requests,
partial failures, retries, cancellation, and out-of-order responses.

## Simulator checks and captures

1. Start `python3 Tests/LibrarySearch/fixture.py` using a non-production Python.
2. Use a disposable simulator with **only** the loopback server
   `http://127.0.0.1:18191` configured. Sign in with `demo@example.test` and any
   invented password; the fixture accepts it. Build/install Open Relay there.
3. Generate the independent test harness using
   `xcodegen generate --spec Tests/LibrarySearch/project.yml`.
4. Run the `LibrarySearch` scheme in the generated project, selecting
   `testDark`, `testLight`, and `testPaginationAndChangingQuery`. The `testBefore`
   case is for the old build only. `testDarkDemo` and `testLightDemo` provide
   short recording flows without error cases.

The UI checks cover the search button, consolidated chat-actions menu, removal of inline sidebar search, empty
state, keyboard placement, all/type filters, body-only chat matches, content-only
document matches, opening chats/folders/files/knowledge bases, no results, partial
failure/retry, clear, and close. Screenshots are attached to the test result.

Validated with an iPhone 16 Pro simulator on iOS 27: the three interaction tests
pass in the Release app, as do the strict-concurrency model/API checks. The old
build's `testBefore` confirms that the body-only chat match is hidden by sidebar
search; the new UI checks confirm that the same synthetic match is visible.

Search uses the server's existing authenticated routes:

- Chats: `/api/v1/chats/search?text=…&page=…`, preserving the server's snippet.
- Folders: `/api/v1/folders/`, filtering folder names locally.
- Knowledge bases: `/api/v1/knowledge/search?query=…&page=…`.
- Document contents: `/api/v1/knowledge/search/files?query=…&include_content=true&page=…`.
- Document previews: `/api/v1/files/{id}/data/content`, requested by lazy result
  rows. Only a short excerpt is retained in search state; JSON decoding and
  excerpt extraction run off the main actor.

Document-content search uses the server's literal search and configured content
search limit, not vector similarity. Older servers without chat snippets can
still return chat results without excerpts. Failures stay scoped to the affected
result category. This feature does not change Open WebUI or build another index.

Before publication, review every capture and the complete diff. Upload only
synthetic captures, never local logs, result bundles, real-library screenshots,
reference images, or device/account configuration.
