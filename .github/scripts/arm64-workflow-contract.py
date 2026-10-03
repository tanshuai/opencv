#!/usr/bin/env python3
"""Cheap PR contract and strict ELF verifier tests; fixtures are data, never executable workloads."""
import hashlib
import importlib.util
import json
import struct
import subprocess
import tempfile
from pathlib import Path

# Update only after a genuine successful full manual compile and complete artifact verification.
COMPILED = '6a2c21f581f48c7d1e59480267f3ca9747c219b9'
ROOT = Path(__file__).resolve().parents[2]
workflow = ROOT / '.github/workflows/arm64-build-checks.yml'
text = workflow.read_text()
assert '      - .github/workflows/arm64-build-checks.yml' in text
assert '      - .github/scripts/arm64-*' in text
assert "if: github.event_name == 'workflow_dispatch'" in text
assert "if: github.event_name == 'pull_request'" in text
assert 'permissions:\n  contents: read' in text
assert 'persist-credentials: false' in text
for line in text.splitlines():
    if 'uses: actions/' in line:
        commit = line.split('@', 1)[1].split()[0]
        assert len(commit) == 40 and all(c in '0123456789abcdef' for c in commit)
subprocess.run(['bash', '-n', str(ROOT / '.github/scripts/arm64-legacy-build.sh')], check=True)
manual_files = ['.github/scripts/arm64-legacy-build.sh', '.github/scripts/arm64-artifact-manifest.py']
for name in manual_files:
    previous = subprocess.check_output(['git', 'show', COMPILED + ':' + name], cwd=str(ROOT))
    assert previous == (ROOT / name).read_bytes(), 'Changed actual compiler/verifier requires a fresh full manual build: ' + name
changed = subprocess.check_output(['git', 'diff', '--name-only', COMPILED, 'HEAD'], cwd=str(ROOT), universal_newlines=True).splitlines()
assert all(name.startswith('.github/') for name in changed), 'C++ source changes require full manual validation'
old = subprocess.check_output(['git', 'show', COMPILED + ':.github/workflows/arm64-build-checks.yml'], cwd=str(ROOT), universal_newlines=True)
old_build = old.split('  build:\n', 1)[1].strip()
new_build = text.split('  build:\n', 1)[1].split('\n  contract:\n', 1)[0].replace("    if: github.event_name == 'workflow_dispatch'\n", '').strip()
assert old_build == new_build, 'Manual full compiler/OCI/artifact contract changed'
module_path = ROOT / manual_files[1]
spec = importlib.util.spec_from_file_location('verifier', str(module_path))
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


def fixture(symbol, soname=None, dependencies=(), machine=183):
    # ELF64 little-endian sections: NULL, STRTAB, DYNSYM, DYNAMIC.
    strings = bytearray(b'\0')
    def add(value):
        offset = len(strings)
        strings.extend(value.encode() + b'\0')
        return offset
    symbol_offset = add(symbol) if symbol else 0
    soname_offset = add(soname) if soname else None
    needed = [add(name) for name in dependencies]
    dynamic = b''.join(struct.pack('<qQ', 1, n) for n in needed)
    if soname_offset is not None:
        dynamic += struct.pack('<qQ', 14, soname_offset)
    dynamic += struct.pack('<qQ', 0, 0)
    symbols = b'\0' * 24
    if symbol:
        symbols += struct.pack('<IBBHQQ', symbol_offset, 0x12, 0, 1, 1, 1)
    string_offset = 64
    symbol_table_offset = string_offset + len(strings)
    dynamic_offset = symbol_table_offset + len(symbols)
    section_offset = dynamic_offset + len(dynamic)
    ident = b'\x7fELF\x02\x01\x01' + b'\0' * 9
    header = struct.pack('<16sHHIQQQIHHHHHH', ident, 3, machine, 1, 0, 0, section_offset, 0, 64, 0, 0, 64, 4, 0)
    sections = b'\0' * 64
    sections += struct.pack('<IIQQQQIIQQ', 0, 3, 0, 0, string_offset, len(strings), 0, 0, 1, 0)
    sections += struct.pack('<IIQQQQIIQQ', 0, 11, 0, 0, symbol_table_offset, len(symbols), 1, 0, 8, 24)
    sections += struct.pack('<IIQQQQIIQQ', 0, 6, 0, 0, dynamic_offset, len(dynamic), 1, 0, 8, 16)
    return header + strings + symbols + dynamic + sections


with tempfile.TemporaryDirectory() as name:
    tmp = Path(name)
    lib = tmp / 'lib'
    lib.mkdir()
    core = 'libopencv_core.so.4.5'
    (lib / core).write_bytes(fixture('core_api', core))
    (lib / 'cv2.so').write_bytes(fixture('initcv2', dependencies=(core,)))
    (lib / 'python3').mkdir()
    (lib / 'python3/cv2.so').write_bytes(fixture('PyInit_cv2', dependencies=(core,)))
    out = tmp / 'complete'
    manifest = v.collect(lib, out, [])
    print('Synthetic ELF-spec fixture positive/negative checks; these are not current C++ compile artifacts')
    v.verify(out)
    assert len(manifest['libraries']) == 3 and not manifest['missing_DT_NEEDED']
    (out / 'python2/cv2.so').write_bytes(b'tampered')
    try:
        v.verify(out)
        raise AssertionError('Hash corruption falsely passed')
    except ValueError:
        pass
    (lib / core).unlink()
    missing = tmp / 'missing'
    metadata = v.collect(lib, missing, [])
    assert core in metadata['missing_DT_NEEDED']
    metadata['missing_DT_NEEDED'] = []
    (missing / 'MANIFEST.json').write_text(json.dumps(metadata))
    try:
        v.verify(missing)
        raise AssertionError('Forged missing list falsely passed')
    except ValueError:
        pass
    try:
        v.elf(fixture('initcv2', machine=62))
        raise AssertionError('Wrong architecture falsely passed')
    except ValueError:
        pass
print('PASS current PR trigger/pins/read permission/bash + positive/negative actual verifier contracts')
print('Current PR validates configuration; full unchanged compiler inputs and 61-ELF acceptance are from reviewed exact compiled commit ' + COMPILED)
