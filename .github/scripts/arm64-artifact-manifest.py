#!/usr/bin/env python3
"""Collect/read ARM64 ELF bytes and require a complete dynamic dependency closure. Never load code."""
import argparse
import hashlib
import json
import shutil
import struct
from pathlib import Path


def elf(data):
    header = struct.unpack_from('<16sHHIQQQIHHHHHH', data)
    if not (header[0][:4] == b'\x7fELF' and header[0][4:6] == b'\x02\x01' and header[2] == 183):
        raise ValueError('Expected ELF64 little-endian AArch64')
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, header[6] + i * header[11]) for i in range(header[12])]
    exports, needed, soname = [], [], None
    for section in sections:
        if section[1] not in (6, 11):
            continue
        table = sections[section[6]]
        strings = data[table[4]:table[4] + table[5]]
        for offset in range(section[4], section[4] + section[5], section[9]):
            if section[1] == 11:
                name, info, other, index, _, _ = struct.unpack_from('<IBBHQQ', data, offset)
                text = strings[name:strings.index(b'\0', name)].decode(errors='replace')
                if info >> 4 in (1, 2) and info & 15 == 2 and index and other & 3 in (0, 3):
                    exports.append(text)
            else:
                tag, index = struct.unpack_from('<qQ', data, offset)
                if tag in (1, 14):
                    text = strings[index:strings.index(b'\0', index)].decode()
                    if tag == 1:
                        needed.append(text)
                    else:
                        soname = text
    return {'architecture': 'AArch64', 'exports': exports, 'DT_NEEDED': needed, 'SONAME': soname}


def collect(libdir, output, sysroots):
    output.mkdir(parents=True, exist_ok=True)
    records, errors, represented = [], [], {}

    def preserve(source, destination):
        raw = source.read_bytes()
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(str(source), str(destination))
        record = {'source': str(source), 'path': str(destination.relative_to(output)), 'size': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
        try:
            info = elf(raw)
            record.update(info)
            if info['SONAME']:
                represented[info['SONAME']] = record
        except Exception as error:
            record['parse_error'] = str(error)
            errors.append(str(source) + ': ' + str(error))
        records.append(record)
        return record

    for source in sorted(libdir.rglob('*.so*')):
        if not source.is_file() or source.is_symlink() or not source.name.startswith(('libopencv_', 'cv2')):
            continue
        try:
            info = elf(source.read_bytes())
            if 'initcv2' in info['exports']:
                destination = output / 'python2' / source.name
            elif 'PyInit_cv2' in info['exports']:
                destination = output / 'python3' / source.name
            elif info['SONAME']:
                destination = output / 'libraries' / info['SONAME']
            else:
                destination = output / 'raw' / source.name
        except Exception:
            destination = output / 'raw' / source.name
        preserve(source, destination)
    # Resolve every DT_NEEDED transitively; a missing library remains a real failed gate.
    index = 0
    missing = set()
    while index < len(records):
        record = records[index]
        index += 1
        for name in record.get('DT_NEEDED', []):
            if name in represented:
                continue
            candidate = next((root / name for root in sysroots if (root / name).is_file()), None)
            if candidate is None:
                missing.add(name)
            else:
                copied = preserve(candidate, output / 'runtime' / name)
                represented[name] = copied
    manifest = {'libraries': records, 'errors': errors, 'missing_DT_NEEDED': sorted(missing), 'generated_code_executed': False}
    (output / 'MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (output / 'SHA256SUMS').write_text(''.join(record['sha256'] + '  ' + record['path'] + '\n' for record in records))
    return manifest


def verify(output):
    manifest = json.loads((output / 'MANIFEST.json').read_text())
    if manifest['errors'] or manifest['missing_DT_NEEDED']:
        raise ValueError('Invalid/incomplete artifact closure: ' + json.dumps({'errors': manifest['errors'], 'missing': manifest['missing_DT_NEEDED']}))
    records = manifest['libraries']
    actual = []
    for record in records:
        raw = (output / record['path']).read_bytes()
        if hashlib.sha256(raw).hexdigest() != record['sha256']:
            raise ValueError('Artifact hash mismatch: ' + record['path'])
        info = elf(raw)
        info['path'] = record['path']
        actual.append(info)
    represented = {r['SONAME'] for r in actual if r['SONAME']}
    represented.update(Path(r['path']).name for r in actual)
    missing = sorted({name for r in actual for name in r['DT_NEEDED'] if name not in represented})
    if missing:
        raise ValueError('Actual ELF dependency closure missing: ' + ', '.join(missing))
    if not any((r.get('SONAME') or '').startswith('libopencv_core.so.') for r in actual):
        raise ValueError('Expected real OpenCV core')
    for symbol in ('initcv2', 'PyInit_cv2'):
        if not any(symbol in r.get('exports', []) for r in actual):
            raise ValueError('Expected Python binding export: ' + symbol)
    print('PASS real AArch64 core, both Python ABIs, SHA256 and complete DT_NEEDED closure')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=('collect', 'verify'))
    parser.add_argument('--libdir', type=Path, default=Path('build/lib'))
    parser.add_argument('--output', type=Path, default=Path('build/arm64-results'))
    parser.add_argument('--sysroot', action='append', type=Path, default=[])
    args = parser.parse_args()
    if args.mode == 'collect':
        collect(args.libdir, args.output, args.sysroot)
    else:
        verify(args.output)
