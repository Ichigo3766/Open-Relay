# Attachment compatibility regression tests

All accounts, chats, documents, settings, and media in this fixture are newly invented. It runs on loopback and does not use an Open WebUI installation, production account, or model provider.

## Focused tests

From the repository root, with the Xcode command-line tools available:

```sh
sh Tests/Attachments/run.sh /path/to/external-test-artifacts
```

The runner compiles production model, history, search, and API-extension sources directly. Network calls are stubbed in the API suite. It checks:

- Native IDs, distinct URLs, `context`, `collection_name`, nested `file`/`data` metadata, and folder types survive serialization and cache round trips.
- An explicitly empty chat-level attachment list stays empty; inactive branches and removed sources are not reconstructed from history.
- Reattaching a source updates its mode without duplicating it. Raster images remain distinct from document/SVG context.
- Search pagination, failed-page retry, end-of-results, cancellation, and stale responses that ignore cancellation.
- Native search routes, offset/page parameters, path escaping, metadata-only file requests, empty-search 404 handling, and visible authentication errors.
- Account upload defaults and effective labels for File Context/Builtin Tools settings.

The five checks in `RegressionTests.swift` reproduce failures on Open Relay 5.9 (`f5b8ce858cd790718a31107d954e6cfe32704bb2`). API contracts were inspected against Open WebUI `8bd8b4fac5e059578ac0c74b3c18d11139f88b7d`.

## Full-app simulator tests

Use a disposable simulator with **only** this fixture account. Never point these tests at a personal or production server. Keep simulator storage, builds, and result bundles on the designated external test volume.

1. Install `aiohttp` and `python-socketio` into an isolated test environment, then run `python -B Tests/Attachments/fixture.py`.
2. Install the candidate Open Relay app. Connect it to `http://127.0.0.1:18191`, signing in as `demo@example.test` with an invented password (the fixture accepts it). Do not copy any real account configuration.
3. With XcodeGen installed, generate the UI-test project from `project.yml` in an external staging directory alongside these three files: `AttachmentsUITests.swift`, `Attachments.xctestplan`, and `project.yml`.
4. Run the `Attachments` scheme on that simulator, with external `-derivedDataPath` and `-resultBundlePath`. Use `-parallel-testing-enabled NO -collect-test-diagnostics never`.

The suite exercises actual app navigation and asserts the HTTP requests received by the fixture: server search beyond the initial page, selection across queries, pagination, collection document browsing, collection and folder attachment, per-document override, the `#` picker, default-setting preservation, follow-up/edit/regeneration, failed removal, another client's removal, and removal after app relaunch.

`testBeforeFollowUp` and `testBeforePickers` are skipped by default. Run those two tests alone against the baseline app with `TEST_RUNNER_ATTACHMENTS_BASELINE=1` when recording the original behavior.

The fixture's assistant reply echoes received attachment metadata. It is evidence of the client's request, **not** a benchmark or test of real model retrieval quality. Its small Knowledge pages deliberately test cursor handling independently of the server's normal page size.

## Visual evidence and privacy

The test plan records actual simulator interaction videos and named screenshots. Export them using `xcrun xcresulttool export attachments`. Review the pixels and entire recording before sharing; strip incidental image/video metadata. Do not publish raw result bundles, accessibility hierarchies, build logs, or simulator configuration.

Screenshots in `Screenshots/` show the original pickers, the updated native navigation and search, collection documents, retrieval controls, upload defaults, and the context-preservation reproduction. The PR includes native screen recordings as well. No screenshot or recording comes from an existing account or personal chat.

| Screen | Before | After |
| --- | --- | --- |
| Files | [Picker](Screenshots/before-files.png) / [search](Screenshots/before-file-search.png) | [Picker](Screenshots/after-files.png) / [search](Screenshots/after-file-search.png) / [dark](Screenshots/dark-files.png) |
| Knowledge | [Picker](Screenshots/before-knowledge.png) | [Picker](Screenshots/after-knowledge.png) / [dark](Screenshots/dark-knowledge.png) |
| Collection documents | Not available | [Search](Screenshots/after-collection-search.png) |
| Knowledge retrieval mode | Not available | [Menu](Screenshots/after-context-menu.png) |
| Upload default | Not available | [Settings](Screenshots/after-upload-settings.png) |
| Saved context | [Focused incorrectly](Screenshots/before-context.png) | [Entire Document retained](Screenshots/after-context.png) |
| Compact `#` results | Initial page only | [Server result](Screenshots/after-hash-search.png) |
| Folder Knowledge sheet | Shared older picker | [Native navigation](Screenshots/after-folder-knowledge.png) |

## Compatibility boundaries

The pickers use the current native Files and Knowledge search endpoints. A server without a Knowledge search endpoint shows a retryable error rather than silently searching an incomplete initial page. Folder listing remains the native unpaginated endpoint with local name filtering. Picker search requests metadata; extracted file content is not fetched merely to list or search attachments.

The standard navigation/search controls adopt the platform appearance. No custom glass recreation or extra UI dependency is introduced. Effective-mode labels describe the configured client/model capabilities; server-side policy still determines actual retrieval behavior.

## Build verification

Verified on the iOS 27 simulator: all 15 candidate UI tests passed, with 0 failures; the two baseline-only capture tests were intentionally skipped. A separate five-test dark-mode run passed. All four focused Swift suites passed, including 65 context assertions. These results cover the synthetic client/API flows described above, not a live provider's retrieval quality.

The candidate was built in Release for the arm64 iOS simulator with Xcode 27. The test build used build-only compiler settings for the existing large SwiftUI expressions and dependency compatibility:

```xcconfig
RELAY_QA_Open_UI = -Xfrontend -solver-expression-time-threshold=60 -Xfrontend -solver-scope-threshold=2000000 -Xfrontend -solver-memory-threshold=2147483648
RELAY_QA_InternalCollectionsUtilities = -Xfrontend -internalize-at-link
OTHER_SWIFT_FLAGS = $(inherited) $(RELAY_QA_$(PRODUCT_MODULE_NAME))
```

These settings were supplied through an external `-xcconfig`; neither project build settings nor dependency sources were changed.
