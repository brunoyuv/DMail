"""Select only current optimized SwiftPM objects and record compiler evidence."""
import hashlib
import json
from pathlib import Path


def optimized_objects(build: Path, excluded: set[str]):
    description_path = build / 'description.json'
    manifest_path = build.parent.parent / 'release.yaml'
    description = json.loads(description_path.read_text())
    required = {'ImapAccountCore', *description['targetDependencyMap']['ImapAccountCore']} - excluded
    objects = set()
    targets = set()
    swift = {}
    clang = {}
    for command in description['swiftCommands'].values():
        module = command['moduleName']
        if module not in required:
            continue
        assert not module.endswith('Tests'), module
        arguments = command['otherArguments']
        optimizations = [item for item in arguments if item.startswith('-O')]
        assert optimizations == ['-O'], (module, optimizations)
        assert '-DDEBUG' not in arguments, module
        assert command['wholeModuleOptimization'], module
        targets.add(module)
        swift[module] = {'flags': optimizations, 'wholeModuleOptimization': True}
        objects.update(Path(path) for path in command['objects'])

    # SwiftPM emits JSON-encoded argument arrays in its YAML command records.
    # Read only clang records rather than requiring a separate YAML dependency.
    is_clang = False
    for line in manifest_path.read_text().splitlines():
        if line.startswith('  "'):
            is_clang = False
        elif line == '    tool: clang':
            is_clang = True
        elif is_clang and line.startswith('    args: '):
            arguments = json.loads(line.removeprefix('    args: '))
            output = Path(arguments[arguments.index('-o') + 1])
            relative = output.relative_to(build)
            module = next(part[:-6] for part in relative.parts if part.endswith('.build'))
            if module not in required:
                continue
            assert not module.endswith('Tests'), module
            optimizations = [item for item in arguments if item.startswith('-O')]
            assert len(optimizations) == 1 and optimizations[0] in ['-O1', '-O2', '-O3', '-Os', '-Oz'], (module, optimizations)
            assert '-DDEBUG=1' not in arguments, module
            targets.add(module)
            objects.add(output)
            evidence = clang.setdefault(module, {'flags': optimizations, 'objectCount': 0})
            assert evidence['flags'] == optimizations, module
            evidence['objectCount'] += 1
    assert {'IMAP', 'ImapAccountCore', 'NIOIMAP', 'NIOIMAPCore', 'NIOSSL', 'SMTP'}.issubset(swift)
    assert {'CNIOBoringSSL', 'CNIOBoringSSLShims'}.issubset(clang)
    assert objects
    for path in objects:
        path.relative_to(build)
        assert path.is_file(), path
    return sorted(objects), targets, {
        'configuration': 'release',
        'descriptionSha256': hashlib.sha256(description_path.read_bytes()).hexdigest(),
        'manifestSha256': hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        'swift': swift, 'clang': clang,
    }
