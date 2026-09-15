"""Synthetic parser coverage; these tests do not assert device power thresholds."""
import csv
import importlib.machinery
import importlib.util
import io
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader('demand_power_summary', str(ROOT / 'scripts/summarize-mail-on-demand-power'))
spec = importlib.util.spec_from_loader(loader.name, loader)
summary = importlib.util.module_from_spec(spec)
loader.exec_module(summary)
BASE = 1789403000000


def fixture(optional_reader=False):
    phases = summary.PHASES if optional_reader else summary.REQUIRED_PHASES
    log, cursor = [], BASE + 250
    for phase in phases:
        log.extend((f'DEMAND_POWER_PHASE {phase} start {cursor}', f'DEMAND_POWER_PHASE {phase} end {cursor + 1500}'))
        cursor += 1500
    log.extend(('DEMAND_POWER_RESULT counts=synthetic', 'Tests run: 1, Failure: 0, Error: 0, Pass: 1, Ignore: 0'))
    rows = [{'timestamp': str(stamp), 'ProcId': '123', 'ProcCpuUsage': '1', 'ChildProcCpuUsage': '2|3|',
             'fps': '60', 'gpuLoad': '25', 'pss': '128', 'soc_thermal': '40'} for stamp in range(BASE, cursor + 1001, 1000)]
    return '\n'.join(log), rows


def encoded(rows):
    output = io.StringIO()
    writer = csv.DictWriter(output, rows[0].keys())
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue()


class OnDemandPowerSummaryTests(unittest.TestCase):
    def test_first_sample_excluded_and_phase_edges_overlap_weighted(self):
        log, rows = fixture()
        rows[0]['ProcCpuUsage'] = '999'
        rows[1]['ProcCpuUsage'], rows[2]['ProcCpuUsage'] = '10', '30'
        report = summary.summarize(log, encoded(rows))
        idle = report['phases'][0]
        self.assertEqual(idle['samples'], 2)
        self.assertEqual(idle['edge_overlap_samples'], 2)
        self.assertEqual(idle['sampled_ms'], 1500)
        self.assertEqual(idle['metrics']['main_cpu_pct']['mean'], 20)
        self.assertEqual(sum(phase['sampled_ms'] for phase in report['phases']), 9000)
        self.assertEqual(report['phases'][1]['metrics']['main_cpu_pct']['mean'], round((30 * 250 + 1 * 1250) / 1500, 6))

    def test_missing_nan_negative_and_partial_children_are_not_zero(self):
        log, rows = fixture()
        rows[1].update(ProcCpuUsage='nan', ChildProcCpuUsage='2|NA|', fps='inf', pss='NA')
        rows[2].update(ProcCpuUsage='-1', ChildProcCpuUsage='NA', gpuLoad='-1')
        idle = summary.summarize(log, encoded(rows))['phases'][0]
        self.assertIsNone(idle['metrics']['main_cpu_pct']['mean'])
        self.assertEqual(idle['missing_main_ms'], 1500)
        self.assertEqual(idle['metrics']['child_observed_cpu_pct']['mean'], 2)
        self.assertEqual(idle['metrics']['child_observed_cpu_pct']['observed_ms'], 750)
        self.assertIsNone(idle['metrics']['child_complete_cpu_pct']['mean'])
        self.assertEqual(summary.child_usage('0|0|'), (0, True))
        self.assertEqual(summary.child_usage('-1|inf|'), (None, False))
        # A missing CPU reading must not discard an independently valid memory reading.
        self.assertEqual(idle['memory_raw']['pss']['mean'], 128)
        self.assertEqual(idle['memory_raw']['pss']['observed_ms'], 750)

    def test_missing_pid_invalidates_reported_app_zero_and_missing_coverage_is_explicit(self):
        log, rows = fixture()
        for row in rows:
            row['ProcId'], row['ProcCpuUsage'] = 'NA', '0'
        report = summary.summarize(log, encoded(rows[:2]))
        self.assertIsNone(report['phases'][0]['metrics']['main_cpu_pct']['mean'])
        self.assertEqual(report['phases'][0]['uncovered_ms'], 750)
        self.assertEqual(report['phases'][-1]['samples'], 0)
        self.assertIsNone(report['phases'][-1]['metrics']['child_observed_cpu_pct']['mean'])

    def test_optional_reader_phase_and_bad_or_incomplete_runs(self):
        log, rows = fixture(True)
        self.assertEqual(len(summary.summarize(log, encoded(rows))['phases']), 7)
        for altered, expected in ((log.replace('reader_idle end', 'unknown end'), 'Unknown phase'),
                                  (log.replace('reader_idle end', 'not_a_marker'), 'Missing phase marker'),
                                  (log.replace('Failure: 0', 'Failure: 1'), 'did not report'),
                                  (log.replace('DEMAND_POWER_RESULT', 'INCOMPLETE'), 'Missing successful'),
                                  (log + f'\nDEMAND_POWER_PHASE idle end {BASE + 100}', 'Conflicting phase')):
            with self.subTest(expected=expected), self.assertRaisesRegex(summary.SummaryError, expected):
                summary.summarize(altered, encoded(rows))

    def test_bad_timestamps_and_large_gaps_are_not_attributed_to_phases(self):
        log, rows = fixture()
        report = summary.summarize(log, encoded(rows[:1] + rows[2:]))
        self.assertEqual(report['rejected_interval_count'], 1)
        self.assertEqual(report['phases'][0]['uncovered_ms'], 1500)
        for stamp in (rows[0]['timestamp'], 'NA', '1.5'):
            modified = [dict(row) for row in rows]
            modified[1]['timestamp'] = stamp
            with self.subTest(stamp=stamp), self.assertRaises(summary.SummaryError):
                summary.summarize(log, encoded(modified))
        with self.assertRaisesRegex(summary.SummaryError, 'Missing profiler CSV field'):
            summary.summarize(log, 'timestamp,ProcCpuUsage\n0,1\n1000,1\n')

    def test_exact_fixture_counter_deltas_preserve_open_and_idle_work(self):
        log, rows = fixture()
        counts = []
        for line in log.splitlines():
            if line.startswith('DEMAND_POWER_PHASE'):
                _, phase, edge, stamp = line.split()
                body = 1 if phase not in ('idle', 'refresh') and not (phase == 'open' and edge == 'start') else 0
                counts.append(f'DEMAND_POWER_COUNTS {phase} {edge} {stamp} 0,0,0,0,{body},0,0,0,0')
        report = summary.summarize(log + '\n' + '\n'.join(counts), encoded(rows))
        self.assertEqual(report['phases'][2]['work']['delta']['body_calls'], 1)
        self.assertEqual(report['phases'][-1]['work']['delta']['body_calls'], 0)

    def test_hiperf_preserves_reported_rows_without_aggregating_percentages(self):
        report = summary.hiperf_summary('Header\n 22.50% 450 ArkUI 123 libace.so PaintFrame(int)\n'
                                        ' 10.00% 200 Render 124 libweb.so Draw()\n'
                                        ' 5.00% unexpected format\nerror: profiling denied\n')
        self.assertEqual(report['status'], 'reported')
        self.assertEqual(report['top_reported_rows'][0]['function'], 'PaintFrame(int)')
        self.assertEqual(report['top_reported_rows'][0]['count'], 450)
        self.assertNotIn('function', report['top_reported_rows'][2])
        self.assertEqual(summary.hiperf_summary('permission denied')['status'], 'unparsed_or_unavailable')

    def test_aa_primary_is_not_labeled_as_app_and_child_identity_requires_reported_evidence(self):
        log, rows = fixture()
        for row in rows:
            row.update(ProcId='123', ProcAppName='aa', ChildProcId='456|0|')
        unknown = summary.summarize(log, encoded(rows))
        self.assertEqual(unknown['process_identity']['primary_column'][0]['name'], 'aa')
        self.assertFalse(unknown['process_identity']['primary_column'][0]['matches_target_name'])
        self.assertNotIn('verified_name', unknown['process_identity']['reported_child_pids'][0])
        report = summary.summarize(log, encoded(rows), hiperf=
            ' 4.31% 1234 org.thunderbird.harmony.imaptest 456 lib.so ioctl\n')
        self.assertEqual(report['process_identity']['reported_child_pids'], [{
            'pid': 456, 'observations': len(rows), 'verified_name': summary.TARGET_BUNDLE,
            'verification': 'HiPerf reports this same TID with the target bundle comm; it matches a SmartPerf child PID.'}])
        self.assertIn('123:aa', summary.table(report))
        self.assertNotIn('AppCPU%', summary.table(report))
        self.assertIn('may omit ArkWeb', summary.table(report))
        self.assertEqual(report['phases'][0]['metrics']['main_cpu_pct']['mean'], 1)
        self.assertEqual(report['phases'][0]['metrics']['child_complete_cpu_pct']['mean'], 5)


if __name__ == '__main__':
    unittest.main()
