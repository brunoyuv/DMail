"""Offline regression tests for phase/sample attribution, not device thresholds."""
import csv
import importlib.machinery
import importlib.util
import io
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader('scroll_power_summary', str(ROOT / 'scripts/summarize-html-scroll-power'))
spec = importlib.util.spec_from_loader(loader.name, loader)
summary = importlib.util.module_from_spec(spec)
loader.exec_module(summary)
BASE = 1789403000000


def fixture():
    markers = []
    cursor = BASE + 250
    for mode in summary.MODES:
        for phase in summary.PHASES:
            markers.extend([f'POWER_PHASE {mode} {phase} start {cursor}',
                            f'POWER_PHASE {mode} {phase} end {cursor + 5000}'])
            cursor += 6000
        markers.append(f'POWER_RESULT {mode} {cursor}')
    markers.append('Tests run: 1, Failure: 0, Error: 0, Pass: 1, Ignore: 0')
    rows = []
    for stamp in range(BASE - 1000, cursor + 1000, 1000):
        row = {'timestamp': str(stamp), 'ProcId': '123', 'ProcCpuUsage': '1',
               'ChildProcCpuUsage': '2|3|', 'gpuLoad': '25', 'fps': '120',
               'soc_thermal': '40', 'currentNow': '-450', 'voltageNow': '7700000'}
        row.update({f'cpu{index}Usage': '0' for index in range(12)})
        rows.append(row)
    return '\n'.join(markers), rows


def encoded(rows):
    output = io.StringIO()
    writer = csv.DictWriter(output, rows[0].keys())
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue()


class ScrollPowerSummaryTests(unittest.TestCase):
    def test_two_mode_picture_run_keeps_phase_request_deltas(self):
        log, rows = fixture()
        lines = [line.replace('baseline011', 'baseline018').replace('current018', 'current019')
                 for line in log.splitlines() if 'asyncViewport' not in line]
        counters = []
        for line in lines:
            if line.startswith('POWER_PHASE '):
                _, mode, phase, edge, stamp = line.split()
                cache = 26 if phase == 'scroll' and edge == 'end' else 24
                counters.append(f'PICTURE_POWER_COUNTS {mode} {phase} {edge} {stamp} '
                                f'resources={cache},cache={cache},good_http=20,missing_http=2,tracker_http=0')
        report = summary.summarize('\n'.join(lines + counters), encoded(rows), modes=('baseline018', 'current019'))
        self.assertEqual(len(report['phases']), 6)
        self.assertEqual(report['phases'][1]['picture_work']['delta']['cache'], 2)
        self.assertEqual(report['phases'][1]['picture_work']['delta']['good_http'], 0)

    def test_full_intervals_first_sample_and_settling_guard(self):
        log, rows = fixture()
        # These endpoints precede the first complete in-phase interval. Neither
        # the first sample nor a boundary-crossing delta can inflate the result.
        for row in rows[:3]:
            row['ProcCpuUsage'] = '999'
        result = summary.summarize(log, encoded(rows))
        idle, _, settled = result['phases'][:3]
        self.assertEqual(idle['samples'], 4)
        self.assertEqual(idle['first_sample_end_ms'], BASE + 2000)
        self.assertEqual(settled['samples'], 3)
        self.assertEqual(settled['eligible_start_ms'], BASE + 13250)
        self.assertEqual(idle['metrics']['complete_process_cpu_pct']['mean'], 6)
        self.assertEqual(idle['metrics']['complete_process_cores']['mean'], .72)
        self.assertEqual(idle['metrics']['current_now_raw']['mean'], -450)
        self.assertEqual(idle['metrics']['voltage_now_raw']['mean'], 7700000)
        self.assertEqual(idle['metrics']['gpu_load_pct']['mean'], 25)
        self.assertEqual(result['cpu_cores'], 12)

    def test_missing_children_remain_missing_and_partial_sum_is_explicit(self):
        log, rows = fixture()
        rows[3]['ChildProcCpuUsage'] = '2|NA|'
        rows[4]['ChildProcCpuUsage'] = 'NA'
        result = summary.summarize(log, encoded(rows))['phases'][0]
        self.assertEqual(result['incomplete_child_samples'], 2)
        self.assertEqual(result['metrics']['child_cpu_pct']['samples'], 3)
        self.assertEqual(result['metrics']['child_cpu_pct']['mean'], 4)
        self.assertEqual(result['metrics']['complete_process_cpu_pct']['samples'], 2)
        self.assertEqual(result['metrics']['complete_process_cpu_pct']['mean'], 6)
        self.assertEqual(result['metrics']['known_process_cpu_pct']['mean'], 4)
        self.assertEqual(summary.child_usage('NA'), (None, False))
        self.assertEqual(summary.child_usage('0|0|'), (0, True))
        self.assertEqual(summary.child_usage('bad|1|'), (1, False))

    def test_partial_failed_or_unsampled_runs_are_rejected(self):
        log, rows = fixture()
        with self.assertRaisesRegex(summary.SummaryError, 'Missing phase marker'):
            summary.summarize(log.replace('POWER_PHASE asyncViewport settled end', 'INCOMPLETE'), encoded(rows))
        with self.assertRaisesRegex(summary.SummaryError, 'Missing successful mode result'):
            summary.summarize(log.replace('POWER_RESULT asyncViewport', 'INCOMPLETE'), encoded(rows))
        with self.assertRaisesRegex(summary.SummaryError, 'did not report one passing test'):
            summary.summarize(log.replace('Failure: 0', 'Failure: 1'), encoded(rows))
        with self.assertRaisesRegex(summary.SummaryError, 'No complete'):
            summary.summarize(log, encoded(rows[:3]))
        rows[3]['timestamp'] = rows[2]['timestamp']
        with self.assertRaisesRegex(summary.SummaryError, 'not strictly increasing'):
            summary.summarize(log, encoded(rows))


if __name__ == '__main__':
    unittest.main()
