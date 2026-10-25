#!/usr/bin/env python3
"""Analyze the versioned development frame trace CSV without graphics timing readbacks."""

import argparse
import csv
import json
import math
import statistics
import sys

PHASES = ("update", "draw", "graphicsSubmit", "headsetSubmit", "present", "gc", "observer")
HEAPS = ("Sync", "Update", "Draw", "GraphicsSubmit", "HeadsetSubmit", "Present", "Gc")
NUMBERS = (
    "sequence", "syncTime", "sync", "interval", *PHASES,
    *(f"heap{phase}KiB" for phase in HEAPS),
    "nativeInterval", "nativeWork", "skipped", "refreshRate", "gcBudgetUs", "betweenFrames", "gcSteps",
)
BOOLEANS = ("active", "visible", "focused", "gpuTiming", "gcCycleCompleted", "gcOverrun", "antialias")
COLUMNS = {"formatVersion", "foveation", "supersample", "executionMode", *NUMBERS, *BOOLEANS}


def read(source):
    """Read version 1 rows; absent timing stays None rather than becoming zero."""
    reader = csv.DictReader(source)
    if set(reader.fieldnames or ()) != COLUMNS or len(reader.fieldnames or ()) != len(COLUMNS):
        raise ValueError("frame trace: unrecognized CSV columns")
    rows = []
    for line, row in enumerate(reader, 2):
        if len(rows) == 10000:
            raise ValueError("frame trace: capture exceeds 10000 rows")
        if None in row or any(value is None for value in row.values()):
            raise ValueError(f"frame trace: malformed CSV row {line}")
        if row["formatVersion"] != "1":
            raise ValueError(f"frame trace: unsupported format version on row {line}")
        for field in NUMBERS:
            value = row[field]
            number = float(value) if value else None
            if number is not None and not math.isfinite(number):
                raise ValueError(f"frame trace: nonfinite {field} on row {line}")
            row[field] = number
        for field in BOOLEANS:
            if row[field] not in ("true", "false", ""):
                raise ValueError(f"frame trace: invalid {field} on row {line}")
            row[field] = {"true": True, "false": False, "": None}[row[field]]
        sequence = row["sequence"]
        if sequence is None or sequence < 0 or sequence % 1 or (rows and sequence <= rows[-1]["sequence"]):
            raise ValueError(f"frame trace: invalid sequence on row {line}")
        if row["syncTime"] is None or (rows and row["syncTime"] < rows[-1]["syncTime"]):
            raise ValueError(f"frame trace: invalid syncTime on row {line}")
        for field in NUMBERS:
            if row[field] is not None and row[field] < 0:
                raise ValueError(f"frame trace: negative {field} on row {line}")
        for field in ("skipped", "gcSteps"):
            if row[field] is not None and row[field] % 1:
                raise ValueError(f"frame trace: fractional {field} on row {line}")
        rows.append(row)
    return rows


def means(rows, fields, scale=1):
    result = {}
    for field in fields:
        values = [row[field] * scale for row in rows if row[field] is not None]
        if values:
            result[field] = statistics.fmean(values)
    return result


def cohort(rows, selected):
    preceding = []
    unaligned = 0
    for index in selected:
        if index and rows[index - 1]["sequence"] + 1 == rows[index]["sequence"]:
            preceding.append(rows[index - 1])
        else:
            unaligned += 1
    heap_deltas = []
    for row in preceding:
        deltas = {}
        for before, after, phase in zip(HEAPS, HEAPS[1:], PHASES):
            first, last = row[f"heap{before}KiB"], row[f"heap{after}KiB"]
            deltas[phase] = None if first is None or last is None or row[phase] is None else last - first
        heap_deltas.append(deltas)
    return {
        "rows": len(selected), "unalignedRows": unaligned,
        "precedingWorkMs": means(preceding, (*PHASES, "betweenFrames"), 1000),
        "precedingNetHeapKiB": means(heap_deltas, PHASES[:-1]),
        "nativePriorWorkAtSyncMs": means([rows[index] for index in selected], ("nativeWork",), 1000),
    }


def analyze(rows):
    """Align long intervals and predicted-target misses independently with prior completed work."""
    missed = [index for index, row in enumerate(rows) if row["skipped"] is not None and row["skipped"] > 0]
    long = [index for index, row in enumerate(rows)
            if row["interval"] is not None and row["refreshRate"] is not None and row["refreshRate"] > 0
            and row["interval"] > 1.5 / row["refreshRate"]]
    intervals = [row["interval"] * 1000 for row in rows if row["interval"] is not None]
    settings = ("active", "visible", "focused", "executionMode", "gpuTiming", "refreshRate", "gcBudgetUs", "supersample", "antialias", "foveation")
    return {
        "rows": len(rows),
        "missedPredictedTargets": sum(rows[index]["skipped"] for index in missed),
        "missingSkippedRows": sum(row["skipped"] is None for row in rows),
        "longSyncIntervals": len(long),
        "unfocusedRows": sum(row["focused"] is False for row in rows),
        "syncIntervalMs": {"mean": statistics.fmean(intervals), "max": max(intervals)} if intervals else {},
        "meanWorkMs": means(rows, ("sync", *PHASES, "betweenFrames"), 1000),
        "predictedTargetMisses": cohort(rows, missed),
        "longIntervals": cohort(rows, long),
        "metadataValues": {field: sorted({str(row[field]) for row in rows}) for field in settings},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("captures", nargs="+", help="exported frame-trace CSV files; repeat for instrumented A/B")
    args = parser.parse_args()
    try:
        results = {}
        for path in args.captures:
            with open(path, newline="", encoding="utf-8") as source:
                results[path] = analyze(read(source))
        print(json.dumps(results, indent=2, allow_nan=False))
    except (OSError, ValueError, csv.Error) as error:
        print(f"frame trace: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
