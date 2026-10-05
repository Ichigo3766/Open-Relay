# File-output persistence regression

Requires macOS with the Swift compiler and Python 3. From the repository root:

```sh
python3 Tests/Bandwidth/file_output_saves.py --output /path/to/build-output
```

The harness compiles the actual file-population method and the persistence blocks
from both completion paths. API, model, logging and parser boundaries use small
synthetic stubs. It verifies that text-only replies, existing server files,
missing messages and repeated extraction do not save; newly extracted files
still update the message/tree and save once. It also checks content preservation.

To reproduce the failure on an earlier revision, add `--ref <revision>`.
Only invented content and file IDs are used. Generated sources, compiler caches
and binaries stay in the requested output directory. This is a native logic
regression, separate from an iOS UI or server integration test.
