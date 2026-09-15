"""Offline numeric sampling tests. Never invoke HDC or production."""
import importlib.machinery
import importlib.util
from pathlib import Path
import unittest
import subprocess

loader = importlib.machinery.SourceFileLoader('mail_runtime_logger', str(Path(__file__).resolve().parents[1] / 'scripts/log-mail-runtime'))
spec = importlib.util.spec_from_loader(loader.name, loader)
logger = importlib.util.module_from_spec(spec)
loader.exec_module(logger)


class RuntimeLoggerTests(unittest.TestCase):
    def test_numeric_rows_preserve_pid_start_identity_and_never_emit_unrecognized_names(self):
        raw = ('P 2002 123 1 123 main 11 2 900 50000 200 4\n'
               'T 2002 123 1 125 compositor 9 1 901 50000 200 4\n'
               'T 2002 123 1 126 private-subject 9 1 901 50000 200 4\n'
               'P 9999 8 1 8 main 2 0 7 300 5 1\n'
               'S 123456 12 1000000\n')
        rows, system = logger.parse_snapshot(raw, 2002, 1, 123456789)
        self.assertEqual(len(rows), 2)
        self.assertEqual(len(rows[0]), len(logger.FIELDS))
        self.assertEqual(rows[0][4], 123)
        self.assertEqual(rows[0][10], 900)
        self.assertEqual(rows[1][7], 'compositor')
        self.assertEqual(system, (123456, 12, 1000000))
        self.assertNotIn('private-subject', str(rows))

    def test_native_thread_totals_keep_missing_user_system_and_start_time_unknown(self):
        raw = ('Q 2002 123 1 125 FFRT 1:02.34\n'
               'Q 2002 123 1 126 other 1:01:02.34\n'
               'Q 2002 123 1 127 private-thread 0:01.00\n'
               'Q 9999 123 1 128 other 0:01.00\n'
               'Q 2002 123 1 129 other 0:90.00\n'
               'Q 2002 123 1 130 other nan\n'
               'S 12345 12 0\n')
        rows, _ = logger.parse_snapshot(raw, 2002, 1, 1000)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0][8:14], ['', '', '', '', '', ''])
        self.assertEqual(rows[0][-1], 62340)
        self.assertEqual(rows[1][-1], 3662340)
        self.assertEqual(rows[0][7], 'FFRT')
        self.assertEqual(len(rows[0]), len(logger.FIELDS))

    def test_closed_app_is_a_successful_empty_snapshot_but_disconnect_is_not(self):
        rows, system = logger.parse_snapshot('S 123 12 1000\n', 2002, 1, 1000)
        self.assertEqual(rows, [])
        self.assertEqual(system[1], 12)
        for raw in ('[Fail] Device not connected', 'S nan 12 1000', 'S 123 0 1000'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                logger.parse_snapshot(raw, 2002, 1, 1000)

    def test_commands_are_bounded_uid_scoped_and_only_stop_the_owned_collector(self):
        command = logger.snapshot_command(2002)
        syntax = subprocess.run(['sh', '-n'], input=command, text=True, capture_output=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        self.assertIn('dmail_uid=2002', command)
        self.assertIn('1024', command)
        self.assertIn('-le 32', command)
        for forbidden in ('cmdline', 'stack', 'hilog', 'screen', 'tcp', 'trace'):
            self.assertNotIn(forbidden, command)
        stop = logger.collector_stop_command(123, 900)
        self.assertIn('"$dmail_name" = SP_daemon', stop)
        self.assertIn('"${20}" = 900', stop)
        self.assertIn('kill -INT 123', stop)
        for value in ('-1', '1;touch /tmp/no', '', 0):
            with self.subTest(value=value), self.assertRaises(ValueError): logger.snapshot_command(value)
            with self.subTest(value=value), self.assertRaises(ValueError): logger.collector_stop_command(value, 1)


if __name__ == '__main__':
    unittest.main()
