# Long-history render checks

Run the production virtualizer and the collection-building portion of `messagesList` against invented rows and a UIKit scroll-view stub:

```sh
python3 Tests/ChatRowVirtualizer/run-tests.py /path/to/external-storage/virtualizer-checks
```

Generated sources, binaries and module caches stay outside the checkout. `--source` and `--view-source` can select previous implementations; previous views without aggregate groups run the anchor checks only.

Checks cover height changes above, within and below the reading anchor; fractional changes; shuffled measurement order; repeated measurements; insertion, removal, reordering and width changes; top/hold/missing-scroll-view behavior. Aggregate groups preserve every logical slot in order, exact summed spacer heights, unique identities, global message indices, and the edited, streaming and last turns. Leading replies, consecutive users and multiple replies preserve complete turns. A 402-message case with two long older turns verifies that visibility, editing and streaming select only ten full rows rather than drawing all replies in those turns. Ordinary alternating histories up to 100,000 messages produce a bounded set of drawn rows even when editing and streaming require additional islands. The last turn retains its existing always-drawn behavior. These component checks complement native scrolling, jump, expansion, rotation and edit tests; they do not measure rendered frame rate.

The optional `--benchmark /path/to/synthetic-response.json` mode uses the real five history/model files. JSON reading and model construction precede timing. It measures 100 unchanged-history anchor/range updates, reports process CPU/wall time, and keeps UIKit stubbed. Use `--source` for a control virtualizer. Peak RSS covers the process lifetime, including fixture loading.

`--benchmark-operation render` measures 100 visible-turn collection builds using the production `messagesList` prefix. `render-forced` also keeps a streaming message and edited message visible. `--value-traversal-control` restores only the two previous value traversals in that extracted prefix, allowing their cost to be compared with indexed reads while holding aggregation and the virtualizer constant. It does not represent the full upstream rendering implementation. Checksums must agree. Both operations use the actual models and exclude JSON/model construction from timing.

Generate the same freshly invented plain fixture used for measurements:

```sh
python3 Tests/ChatRowVirtualizer/generate-fixture.py 6000 /external/plain-6000.json
```

Use 12000 or 100000 for larger fixtures. Generated inputs remain outside the checkout.
