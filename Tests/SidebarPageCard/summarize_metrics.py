"""Summarize exported XCTest metrics without copying device/account metadata.

Usage: python3 summarize_metrics.py before=before-1.json after=after-1.json ...
Each measured block contains two complete sidebar open/close cycles.
"""
import json
import statistics
import sys
from collections import defaultdict

METRICS = {
    "com.apple.dt.XCTMetric_CPU-com.openui.openui.time": ("App CPU per open/close cycle (ms)", "s", 500),
    "com.apple.dt.XCTMetric_CPU-com.openui.openui.instructions_retired": ("CPU instructions per cycle (million)", "kI", 0.0005),
    "com.apple.dt.XCTMetric_Memory-com.openui.openui.physical_peak": ("Peak physical memory per block (MB)", "kB", 0.001),
    "com.apple.dt.XCTMetric_Memory-com.openui.openui.physical_absolute": ("Reported absolute physical memory (MB)", "kB", 0.001),
    "com.apple.dt.XCTMetric_Clock.time.monotonic": ("Automated open/close round trip (ms)", "s", 500),
}


def summarize(arguments):
    samples = defaultdict(lambda: defaultdict(list))
    runs = defaultdict(lambda: defaultdict(list))
    for argument in arguments:
        label, path = argument.split("=", 1)
        with open(path) as source:
            results = json.load(source)
        for result in results:
            for run in result["testRuns"]:
                for metric in run["metrics"]:
                    identifier = metric["identifier"]
                    if identifier not in METRICS:
                        continue
                    _, unit, multiplier = METRICS[identifier]
                    assert metric["unitOfMeasurement"] == unit, "Unexpected metric unit"
                    values = [value * multiplier for value in metric["measurements"]]
                    if values:
                        samples[identifier][label].extend(values)
                        runs[identifier][label].append(statistics.mean(values))
    print("Values are mean ± sample standard deviation; recording is disabled during measurement.")
    print("Clock measurements include XCTest event delivery and idle waits, not just app latency.\n")
    print("| Metric | Before | After | Change |")
    print("| --- | ---: | ---: | ---: |")
    for identifier, (title, _, _) in METRICS.items():
        before, after = (samples[identifier][label] for label in ("before", "after"))
        if not before or not after:
            continue
        means = [statistics.mean(values) for values in (before, after)]
        cells = [f"{statistics.mean(values):.2f} ± {statistics.stdev(values):.2f}" if len(values) > 1
                 else f"{values[0]:.2f}" for values in (before, after)]
        change = f"{(means[1] / means[0] - 1) * 100:+.1f}%" if means[0] else "n/a"
        print(f"| {title} | {' | '.join(cells)} | {change} |")
    print("\nPer-run means (same order as input arguments within each variant):")
    for identifier, (title, _, _) in METRICS.items():
        for label in ("before", "after"):
            values = runs[identifier][label]
            if values:
                print(f"- {title}, {label}: {', '.join(f'{v:.2f}' for v in values)} "
                      f"({len(samples[identifier][label])} measured blocks)")


if __name__ == "__main__":
    summarize(sys.argv[1:])
