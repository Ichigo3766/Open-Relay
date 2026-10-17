# Connection status comparison

Discussion draft. All screenshots and recordings use freshly invented content on a loopback fixture. Connection states/cache flags are injected into the production views only in the test build. The send-error examples use a real HTTP 503 failure from the invented history-save endpoint. No real service or account data is used.

| Name | Before | After |
| --- | --- | --- |
| Server unreachable, saved index | A dismissible banner covers the toolbar.<br><img src="before-server.png" width="220"> | One toolbar badge; tap for status/actions.<br><img src="after-server.png" width="220"> |
| Server unreachable, no index | A full-screen overlay blocks navigation.<br><img src="before-blocking.png" width="220"> | The same badge, with navigation and drafting available.<br><img src="after-blocking.png" width="220"> |
| No internet | Another banner/overlay presentation.<br><img src="before-offline.png" width="220"> | Offline in the same control; the sidebar uses the same state.<br><img src="after-offline.png" width="220"> |
| Connected sidebar | No shared reachability indicator.<br><img src="before-sidebar-connected.png" width="220"> | Green dot beside Open Relay; the connected chat toolbar stays quiet.<br><img src="after-sidebar-connected.png" width="220"> |
| Initial connection check | No visible distinction from connected.<br><img src="before-checking.png" width="220"> | Connecting… until the server is verified. Recovery uses Reconnecting….<br><img src="after-checking.png" width="220"> |
| Send error, keyboard closed | The notice overlaps editable draft text.<br><img src="before-draft-closed-portrait.png" width="220"> | An opaque status row occupies space above the composer.<br><img src="after-draft-closed-portrait.png" width="220"> |
| Send error, keyboard open | The notice jumps into chat content.<br><img src="before-draft-portrait.png" width="220"> | The notice remains adjacent to the input.<br><img src="after-draft-portrait.png" width="220"> |
| Landscape, keyboard open | The notice is offscreen.<br><img src="before-draft-landscape.png" width="300"> | The notice remains visible above the draft.<br><img src="after-draft-landscape.png" width="300"> |

[Before draft recording](draft-before.mp4) · [After draft recording](draft-after.mp4)

Additional views: [offline sidebar](after-sidebar-offline.png), [reconnecting](after-reconnecting.png), [connected toolbar](after-connected.png), [retry menu](after-connection-actions.png), [landscape draft before](before-draft-closed-landscape.png) / [after](after-draft-closed-landscape.png).

Validation: Release build; 23 focused monitor checks; 12 native iPhone UI scenarios, including portrait/landscape, keyboard transitions, retries and dismissing a send-error notice without losing the draft. The final composer checks fail against the control and pass after the change. iPad code was compiled; native screenshots/tests use iPhone.

See `Tests/ConnectionStatus` for the invented fixture and checks. Media metadata is removed and landscape orientation normalized. No application test hooks are shipped in production.
