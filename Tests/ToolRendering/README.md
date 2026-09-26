# Pending tool-content rendering regression

Run on macOS with Xcode installed:

```sh
python3 Tests/ToolRendering/test.py
```

The harness compiles the production parser, cache, history decoder, and the actual
pending-parse fallback extracted from `AssistantMessageContent`. It does not copy
the fallback implementation. Fixtures are entirely invented; no network or
account is needed. It checks initial cache misses, structured and legacy tool
results, cache completion, retaining previously parsed content, and ordinary math.
It tests the rendering boundary, not SwiftUI scheduling or the math library.

To verify the regression against the unfixed revision:

```sh
python3 Tests/ToolRendering/test.py --ref b38bfe9
```

That fails because the pending result contains a raw Markdown text segment.
In the app, literal tool output such as `$$a\\{b\\c\\d$$` can then reach
`SwiftMath.MTMathListBuilder.buildTable` and trap before parsing finishes.
After parsing, the same text belongs in a literal tool-result view instead.
