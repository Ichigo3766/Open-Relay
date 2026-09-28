# Navigation toolbar consistency

This pass replaces text-only navigation actions with native icon-only controls:
X for cancellation/dismissal and checkmark for committing an editor. It preserves
the localized action labels for accessibility, placement, callbacks, disabled
conditions, loading states, and discard confirmations. No custom glass is drawn;
SwiftUI provides the appropriate toolbar appearance on each supported OS.

## Scope

- Settings: defaults, shortcut actions, profile variables, server editing, accent
  color editing, and the in-call voice-settings dismissal.
- Chat/library: folder creation/editing/moving/sharing, conversation renaming,
  selection-mode cancellation, archived/shared previews, and file previews.
- Workspace: model, prompt, skill, tool, knowledge, valve, and picker editors.
- Admin: connection/integration editors, users/groups, banners, events, external
  knowledge, model settings, image workflows, functions/valves, and feedback.
- Other sheets: channel creation/threads, automations, auth cancellation, read
  aloud transcripts, code/HTML/diagram/image/tool-output previews, feedback,
  note/chat pickers, and the fullscreen content editor.

Alerts, confirmation dialogs, keyboard Done buttons, inline form actions,
destructive actions, and system back navigation remain unchanged. Changes already
covered by the separate context, prompt-variable, and calendar PRs are not repeated.

## Automated checks

```sh
python3 Tests/ToolbarConsistency/audit.py
```

The source audit covers navigation toolbar actions throughout `Open UI`, including
localized and conditional labels. The old-style action check fails on baseline
`4151a735512d5d6dbc9fd1962fa806517a0d4ea7` (Open Relay 6.0). It also checks that:

- Before/after callbacks, labels, and placements match exactly.
- The production diff contains presentation changes only.
- Inline/alert/keyboard actions are excluded.
- Navigation close buttons do not contain a pre-circled X.

## Simulator checks

Use a disposable simulator containing **only** a loopback fixture account. Start
`python3 Tests/ToolbarConsistency/fixture.py`, add `http://127.0.0.1:18191` in the
app, and sign in with invented values. The fixture returns an empty library and
an invented demo model/account; it never contacts another service.

Build and install the normal `Open UI` simulator target, then:

```sh
cd Tests/ToolbarConsistency
xcodegen generate
xcodebuild -project ToolbarConsistency.xcodeproj -scheme ToolbarConsistency \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -derivedDataPath /path/to/test-output \
  -resultBundlePath /path/to/results.xcresult \
  -parallel-testing-enabled NO -collect-test-diagnostics never test
```

The tests navigate the real app, capture My Defaults, the shortcut editor, model
editor, and Add User in both light/dark mode, and dismiss each through its toolbar.
They also exercise disabled Save, valid shortcut saving/deletion, and unsaved-model
discard confirmation. The same tests run before and after the styling change.
The broader screen inventory is source-checked and compiled, not claimed as an
exhaustive runtime test of every backend operation.

Only individually reviewed, synthetic-only screenshots belong in `Screenshots/`.
Do not commit result bundles, logs, accessibility hierarchies, or real account data.

## Results

- Five source checks pass; 114 legacy text actions are converted, plus two
  selection-mode controls and an explicitly icon-only file-preview close button.
- Release simulator build passes with the deployment target unchanged.
- iOS 26.5: nine real-app UI checks pass before and after (eight light/dark screen
  cases and the save/discard interaction case).
- Sixteen reviewed before/after screenshots cover the four representative screens
  in both themes. They contain only empty forms and fresh fixture data.
