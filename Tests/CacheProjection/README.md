# Cache projection checks

```sh
python3 Tests/CacheProjection/run-tests.py /path/to/external-storage/projection-checks
```

The tests compile the production projection, detail parser, scanners and history models. Fixtures are newly invented and cover plain/multiline/Unicode text, reasoning and tool cards, flat/tree agreement, user and unfinished messages, visible files/embeds, malformed and partial details, structured output, and Unicode-escaped tags and keys, and UTF-16/32 JSON. Only the unrelated terminal file/image-storage integrations are stubbed. Generated binaries and module caches stay outside the checkout.

Use `--source` for a control implementation, or `--benchmark /path/to/synthetic-response.json` to measure one projection call in an optimized fresh process. Fixture reading precedes timing; reported peak RSS covers the process lifetime.

Generate the same freshly invented plain fixture used for measurements:

```sh
python3 Tests/CacheProjection/generate-fixture.py 6000 /external/plain-6000.json
```

Use 12000 or 100000 for larger fixtures. Generated inputs remain outside the checkout.
