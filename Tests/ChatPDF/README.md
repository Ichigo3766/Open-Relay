# Local chat PDF export

Baseline: Open Relay 6.0, `4151a735512d5d6dbc9fd1962fa806517a0d4ea7`.
Server contract reviewed: Open WebUI `8bd8b4fac5e059578ac0c74b3c18d11139f88b7d`.

The old export fetched the conversation a second time and called the absent
`POST /api/v1/utils/pdf` route. `baseline.py` compiles the old method with a
mocked 404 response and reproduces that failure. The simulator fixture also
returns 404 for that route.

## Focused checks

Run `python3 Tests/ChatPDF/baseline.py` and `python3 Tests/ChatPDF/run.py`
on macOS with Swift and PDFKit available. The second command compiles the actual
exporter, message model and tool parser. Terminal attachment parsing alone is
stubbed because it is not used by text export.

The 149 checks cover pagination, every numbered line and the final marker,
Unicode, reasoning/tool text, attachment labels without downloads, safe unique
filenames, empty chats, long unbroken text, orphan headings and cancelled-export
cleanup. All four pages of the synthetic multi-page output were rendered and
visually inspected. The iPhone and iPad export call sites are also checked.

## Simulator reproduction

Use an isolated simulator account, never an existing server or personal chats.
Install the baseline or changed app and connect it to `http://127.0.0.1:18191`.
The fixture accepts invented credentials and returns only invented craft text.

1. Install `aiohttp` in an isolated test environment and run `fixture.py`.
2. Generate the standalone UI test project with `xcodegen generate --spec project.yml`.
3. Run `PDFUITests/testBefore` on the baseline app, or `PDFUITests/testExport`
   on the changed app. The test target drives an already installed app.

The before test requires the export error and two chat fetches. The after test
requires the native share sheet, one chat fetch, no obsolete PDF request, no
file-content requests, and readable content in the native Markup preview.

Validation used a Release simulator build and iPhone simulator on iOS 26.5.
iPad uses the same exporter and passes the full build/call-site checks; its
share popover was not separately exercised. Earlier UI runs used incorrect
system-control locators; the final test checks native cells and rendered PDF
text rather than assuming a particular toolbar button.

## Scope

This is a **paginated text export**, not a screenshot of the chat: Markdown
notation remains text, attachment names are listed, and media/interactive HTML
are not embedded or fetched. PDF creation runs off the main actor and writes
to a temporary file. The existing share-sheet cleanup remains in use.

Screenshots and all fixture content were freshly invented for these tests;
no user chats, instance configuration, credentials or logs are included.
