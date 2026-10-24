#!/usr/bin/env python3
"""Bind every archive to the same source snapshot and workflow run."""
import hashlib
import json
import os
from pathlib import Path
import sys

HOSTS = ('amazonlinux2','alinux3','centos7','ubuntu22')
TARGET = 'x86_64-unknown-linux-gnu'


def digest(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'not a regular artifact: {path}')
    with path.open('rb') as f:
        result = hashlib.sha256()
        for block in iter(lambda: f.read(1024 * 1024), b''):
            result.update(block)
        return result.hexdigest()


def provenance(label, source):
    if label not in HOSTS or source['artifact_sha'] != os.environ['ARTIFACT_SHA']:
        raise ValueError('artifact run or host mismatch')
    return dict(schema=1, host=label, target=TARGET, source_sha=source['source_sha'],
                artifact_sha=source['artifact_sha'], ctng_commit=source['ctng_commit'],
                metadata_sha256=source['files'])


def process(mode, directory):
    source = json.loads(Path('.candidate-source/source.json').read_bytes())
    labels = [sys.argv[3]] if mode == 'record' else HOSTS
    for label in labels:
        filename = f'{TARGET}-{label}.tar.xz'
        archive = directory/filename
        actual = digest(archive)
        checksum = directory/(filename+'.sha256')
        digest(checksum)
        if checksum.read_text().split()[0] != actual:
            raise ValueError(f'checksum mismatch: {filename}')
        expected = dict(provenance(label,source), archive=filename, archive_sha256=actual)
        manifest = directory/(filename+'.manifest.json')
        if mode == 'record':
            manifest.write_text(json.dumps(expected,sort_keys=True)+'\n')
        elif mode == 'verify':
            digest(manifest)
            if json.loads(manifest.read_bytes()) != expected:
                raise ValueError(f'artifact provenance mismatch: {filename}')
        else:
            raise ValueError('unknown artifact command')


if __name__ == '__main__':
    try:
        process(sys.argv[1],Path(sys.argv[2]))
    except (ValueError,KeyError,IndexError,OSError) as exc:
        print(f'ARTIFACT_VERIFICATION_FAILED: {exc}',file=sys.stderr)
        sys.exit(1)
