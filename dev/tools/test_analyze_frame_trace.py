"""Checks the development CSV wire and preceding-frame timing alignment."""

import csv
import importlib.util
import io
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("analyze_frame_trace", Path(__file__).parent / "analyze_frame_trace.py")
assert SPEC and SPEC.loader
trace = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(trace)


class AnalysisTests(unittest.TestCase):
    def csv(self, rows):
        result = io.StringIO()
        writer = csv.DictWriter(result, sorted(trace.COLUMNS))
        writer.writeheader()
        writer.writerows(rows)
        result.seek(0)
        return result

    def row(self, sequence, interval, update, skipped):
        row = {field: "" for field in trace.COLUMNS}
        row.update(formatVersion="1", sequence=sequence, syncTime=sequence / 90, sync=.007,
                   interval=interval, update=update, draw=.002, graphicsSubmit=.001, headsetSubmit=.001,
                   present=.001, gc=.0002, observer=.00001, betweenFrames=.0003, heapSyncKiB=200,
                   heapUpdateKiB=230, heapDrawKiB=220, heapGraphicsSubmitKiB=221, heapHeadsetSubmitKiB=222,
                   heapPresentKiB=223, heapGcKiB=190, active="true", visible="true", focused="false",
                   nativeInterval=interval, nativeWork=.004, skipped=skipped, refreshRate=90, gcBudgetUs=200,
                   executionMode="tiered", gpuTiming="false", supersample="false", antialias="true", foveation="low",
                   gcSteps=1, gcCycleCompleted="false", gcOverrun="false")
        return row

    def test_missed_interval_uses_preceding_completed_work(self):
        result = trace.analyze(trace.read(self.csv([self.row(1, .011, .008, 0), self.row(2, .022, .001, 1)])))
        self.assertEqual(result["missedPredictedTargets"], 1)
        self.assertAlmostEqual(result["predictedTargetMisses"]["precedingWorkMs"]["update"], 8)
        self.assertEqual(result["unfocusedRows"], 2)
        self.assertAlmostEqual(result["predictedTargetMisses"]["precedingNetHeapKiB"]["update"], 30)

    def test_long_interval_aligns_even_when_no_predicted_target_is_skipped(self):
        result = trace.analyze(trace.read(self.csv([self.row(1, .011, .008, 0), self.row(2, .022, .001, 0)])))
        self.assertEqual(result["missedPredictedTargets"], 0)
        self.assertAlmostEqual(result["longIntervals"]["precedingWorkMs"]["update"], 8)

    def test_sequence_gaps_do_not_align_unrelated_work(self):
        result = trace.analyze(trace.read(self.csv([self.row(1, .011, .008, 0), self.row(4, .022, .001, 1)])))
        self.assertEqual(result["predictedTargetMisses"]["unalignedRows"], 1)
        self.assertEqual(result["predictedTargetMisses"]["precedingWorkMs"], {})

    def test_missing_native_timing_does_not_become_zero(self):
        row = self.row(1, .022, .008, "")
        row.update(nativeInterval="", nativeWork="")
        result = trace.analyze(trace.read(self.csv([row])))
        self.assertEqual(result["missingSkippedRows"], 1)
        self.assertEqual(result["longSyncIntervals"], 1)

    def test_version_nonfinite_values_and_reordered_sequences_are_rejected(self):
        for field, value in [("interval", "nan"), ("formatVersion", "2")]:
            row = self.row(1, .011, .001, 0)
            row[field] = value
            with self.assertRaises(ValueError):
                trace.read(self.csv([row]))
        with self.assertRaises(ValueError):
            trace.read(self.csv([self.row(2, .011, .001, 0), self.row(1, .011, .001, 0)]))

    def test_nonnegative_measurements_and_integral_step_counts_are_required(self):
        for field, value in [(field, -1) for field in ("sync", "betweenFrames", "gcSteps", "syncTime", "heapSyncKiB")] + [("gcSteps", .5)]:
            with self.subTest(field=field, value=value):
                row = self.row(1, .011, .001, 0)
                row[field] = value
                with self.assertRaises(ValueError):
                    trace.read(self.csv([row]))

    def test_row_limit_is_enforced_before_reading_the_remaining_input(self):
        rows = self.csv(self.row(index, .011, .001, 0) for index in range(1, 10001))
        self.assertEqual(len(trace.read(rows)), 10000)
        oversized = self.csv(self.row(index, .011, .001, 0) for index in range(1, 10002))

        def source():
            yield from oversized
            self.fail("reader consumes input after the first row beyond the limit")

        with self.assertRaisesRegex(ValueError, "exceeds 10000 rows"):
            trace.read(source())

    def test_csv_quotes_are_parsed_and_empty_captures_are_explicit(self):
        row = self.row(1, .011, .001, 0)
        row["foveation"] = "low,custom"
        self.assertEqual(trace.read(self.csv([row]))[0]["foveation"], "low,custom")
        self.assertEqual(trace.analyze([])["rows"], 0)


if __name__ == "__main__":
    unittest.main()
