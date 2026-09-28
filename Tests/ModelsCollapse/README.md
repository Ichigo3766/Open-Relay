# Collapsible Models verification

This fixture contains only freshly invented models, a folder, and a demo account.
Never point these tests at a real server or run them on a personal simulator.

1. Run `python3 -B Tests/ModelsCollapse/fixture.py` on the host.
2. Build and install Open Relay on an isolated iPhone simulator.
3. Generate the standalone UI-test project with
   `xcodegen generate --spec Tests/ModelsCollapse/project.yml --project Tests/ModelsCollapse`.
4. Run the `ModelsCollapseTests` scheme against that simulator, excluding
   `testBefore` (which captures the unmodified baseline). The tests connect
   to `http://127.0.0.1:18191` and use the fixture's demo sign-in if needed.

The light/dark UI checks exercise expand/collapse, visibility of neighboring
sections, persistence across relaunch, and selecting a pinned model afterward.
Named screenshot attachments are retained in the result bundle. The application
must be installed separately; this test target does not modify its build settings.
