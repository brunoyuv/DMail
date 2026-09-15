#!/usr/bin/env python3
"""Regression coverage for shipping optimized object selection and provenance."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('imap_build_optimization', root / 'scripts/imap_build_optimization.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class OptimizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.build = Path(self.temp.name) / 'build/triple/release'
        self.build.mkdir(parents=True)
        self.swift = ['IMAP', 'ImapAccountCore', 'NIOIMAP', 'NIOIMAPCore', 'NIOSSL', 'SMTP']
        self.clang = ['CNIOBoringSSL', 'CNIOBoringSSLShims']
        self.description = {
            'targetDependencyMap': {'ImapAccountCore': self.swift + self.clang + ['MIME']},
            'swiftCommands': {},
        }
        for name in self.swift + ['MIME', 'UnusedDiagnostic']:
            output = self.build / f'{name}.build/current.swift.o'
            if name != 'UnusedDiagnostic':
                output.parent.mkdir(parents=True)
                output.touch()
            self.description['swiftCommands'][name] = {
                'moduleName': name, 'otherArguments': ['-O'], 'wholeModuleOptimization': True,
                'objects': [str(output)],
            }
        self.commands = {}
        for name in self.clang:
            output = self.build / f'{name}.build/current.c.o'
            output.parent.mkdir(parents=True)
            output.touch()
            self.commands[name] = ['clang', '-O2', '-c', 'source.c', '-o', str(output)]

    def verify(self):
        (self.build / 'description.json').write_text(json.dumps(self.description))
        (self.build.parent.parent / 'release.yaml').write_text('commands:\n' + '\n'.join(
            f'  "{name}":\n    tool: clang\n    args: {json.dumps(args)}'
            for name, args in self.commands.items()))
        return module.optimized_objects(self.build, {'MIME'})

    def test_selects_only_current_required_objects_and_records_flags(self):
        stale = self.build / 'IMAP.build/removed.swift.o'
        stale.touch()
        objects, targets, evidence = self.verify()
        self.assertEqual(len(objects), len(self.swift) + len(self.clang))
        self.assertNotIn(stale, objects)
        self.assertNotIn('MIME', targets)
        self.assertNotIn('UnusedDiagnostic', targets)
        self.assertEqual(evidence['configuration'], 'release')
        self.assertEqual(evidence['swift']['IMAP']['flags'], ['-O'])
        self.assertEqual(evidence['clang']['CNIOBoringSSL']['flags'], ['-O2'])
        self.assertEqual(evidence['clang']['CNIOBoringSSL']['objectCount'], 1)

    def test_rejects_nonoptimized_swift(self):
        self.description['swiftCommands']['NIOIMAPCore']['otherArguments'] = ['-Onone']
        with self.assertRaises(AssertionError):
            self.verify()

    def test_rejects_later_nonoptimized_override(self):
        self.description['swiftCommands']['NIOSSL']['otherArguments'] = ['-O', '-Onone']
        with self.assertRaises(AssertionError):
            self.verify()

    def test_rejects_debug_assertion_build(self):
        self.description['swiftCommands']['IMAP']['otherArguments'].append('-DDEBUG')
        with self.assertRaises(AssertionError):
            self.verify()

    def test_rejects_nonoptimized_c(self):
        self.commands['CNIOBoringSSL'][1] = '-O0'
        with self.assertRaises(AssertionError):
            self.verify()

    def test_rejects_missing_planned_object(self):
        Path(self.description['swiftCommands']['ImapAccountCore']['objects'][0]).unlink()
        with self.assertRaises(AssertionError):
            self.verify()

    def test_rejects_missing_required_module_provenance(self):
        del self.description['swiftCommands']['NIOSSL']
        with self.assertRaises(AssertionError):
            self.verify()


if __name__ == '__main__':
    unittest.main()
