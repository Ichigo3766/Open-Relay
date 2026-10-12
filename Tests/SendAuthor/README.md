# Send-author exclusivity regression

Run on macOS with Python 3 and the Xcode command-line tools:

```sh
python3 Tests/SendAuthor/run-tests.py /external/scratch
```

The runner compiles the production assistant-placeholder append, author calculation, shared-chat getter, and message author setter in an optimized observable-model fixture. Generated sources, module caches, and binaries stay outside the checkout. Inputs are newly invented; no app container, existing chat, configuration, or credential is read.

The old append evaluates the shared-chat getter while holding an exclusive mutation of the same conversation. Its fresh subprocess aborts before a request could be sent. The fixed control covers six owner/viewer combinations and a missing conversation, verifying count, author, and streaming-placeholder preservation. `--root` accepts a prior checkout for the failing control. Core dumps are disabled and failing subprocess output is reduced to the exit code and whether it contained an exclusivity trap.
