These checks use newly invented synthetic content and the production cache/parser sources. No running server is required.

Run the optimized macOS checks with `python3 Tests/TieredCache/run-conversation-cache-tests.py /path/to/external/scratch`.

For the native placeholder check, run `python3 Tests/TieredCache/generate-loader-project.py /path/to/external/loader`, then build and test the generated `Regression` scheme on an available iOS simulator. XcodeGen is required. Keep generated projects, build products, and results outside this checkout.

The checks cover compact/full promotion, byte budgets, legacy records, expiry, HTTP cache directives, concurrent validation/hydration, account isolation, pending writes during clear, projection fidelity, media retention, unfinished blocks, and placeholder failure behavior.
