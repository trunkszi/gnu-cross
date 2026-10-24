#!/usr/bin/env python3
"""One immutable source tree shared by matrix cells and publication."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

TARGET = 'targets/x86_64-unknown-linux-gnu'
IDENTITY = 'Nathan Shea <itzrustz@gmail.com>'


def git(*args, env=None, data=None):
    return subprocess.check_output(['git', *args], env=env, input=data).decode().strip()


def sha(value):
    if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{40}', value):
        raise ValueError('invalid source SHA')
    return value


def locked():
    return dict(line.split('=', 1) for line in Path(TARGET, 'versions').read_text().splitlines()
                if '=' in line and not line.startswith('#'))


def version_summary():
    value = locked()
    return (f"ct-ng {value['CTNG_RELEASE_TAG']}@{value['CTNG_COMMIT']}; "
            f"GCC {value['EXPECTED_GCC_VERSION']}; mold {value['EXPECTED_MOLD_VERSION']}; "
            f"binutils {value['EXPECTED_BINUTILS_VERSION']}; Linux {value['EXPECTED_LINUX_VERSION']}")


def emit(**values):
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as f:
            for key, value in values.items():
                f.write(f'{key}={str(value).lower() if isinstance(value,bool) else value}\n')


def source_run():
    run = os.environ.get('SOURCE_RUN_ID', '')
    if not run:
        value = sha(os.environ['GITHUB_SHA'])
    else:
        if not re.fullmatch('[1-9][0-9]*', run):
            raise ValueError('invalid source_run_id')
        repo = os.environ['GITHUB_REPOSITORY']
        doc = json.loads(subprocess.check_output(['gh','api',f'repos/{repo}/actions/runs/{run}']))
        if not isinstance(doc, dict) or not isinstance(doc.get('repository'), dict) or not isinstance(doc.get('head_repository'), dict):
            raise ValueError('source run response is missing repository identity')
        if not (doc.get('status') == 'completed' and doc.get('conclusion') == 'success'
                and doc.get('repository',{}).get('full_name','').casefold() == repo.casefold()
                and doc.get('head_repository',{}).get('full_name','').casefold() == repo.casefold()
                and doc.get('path') == '.github/workflows/release.yaml'
                and doc.get('head_branch') == 'main'
                and doc.get('event') in ('schedule','workflow_dispatch')):
            raise ValueError('source run is not a successful trusted release workflow on main')
        value = sha(doc.get('head_sha'))
    emit(artifact_sha=value)
    print(value)


def prepare(dest, updated):
    dest = Path(dest).resolve()
    dest.mkdir(parents=True, exist_ok=True)
    base = sha(os.environ['GITHUB_SHA'])
    version = locked()
    ctng = sha(version['CTNG_COMMIT'])
    with tempfile.TemporaryDirectory(prefix='gnu-source-') as tmp:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(tmp)/'index'))
        git('read-tree', base, env=env)
        if updated:
            git('add', '--', f'{TARGET}/config', f'{TARGET}/versions', env=env)
            git('update-index','--cacheinfo',f'160000,{ctng},builder',env=env)
            tree = git('write-tree',env=env)
            timestamp = git('show','-s','--format=%ct',base)
            identity = dict(env, GIT_AUTHOR_NAME='Nathan Shea', GIT_AUTHOR_EMAIL='itzrustz@gmail.com',
                            GIT_COMMITTER_NAME='Nathan Shea', GIT_COMMITTER_EMAIL='itzrustz@gmail.com',
                            GIT_AUTHOR_DATE=f'@{timestamp} +0000', GIT_COMMITTER_DATE=f'@{timestamp} +0000')
            # commit-tree writes a single root object and prints only its object ID.
            candidate = sha(git('commit-tree',tree,env=identity,data=b'first commit\n'))
        else:
            candidate = base
        ref = f'refs/gnu-cross-candidate/{candidate}'
        git('update-ref', ref, candidate)
        try:
            git('bundle','create',str(dest/'candidate.bundle'),ref)
        finally:
            git('update-ref','-d',ref,candidate)
    doc = {'schema':1,'source_sha':candidate,'artifact_sha':base,'ref':ref,
           'upstream_updated':updated,'ctng_commit':ctng,
           'files':{name:hashlib.sha256(git_bytes(candidate,f'{TARGET}/{name}')).hexdigest()
                    for name in ('config','versions')}}
    (dest/'source.json').write_text(json.dumps(doc,sort_keys=True)+'\n')
    emit(source_sha=candidate)
    print(candidate)


def git_bytes(commit, path):
    return subprocess.check_output(['git','show',f'{commit}:{path}'])


def restore(dest, expected):
    dest = Path(dest).resolve()
    doc = json.loads((dest/'source.json').read_bytes())
    source = sha(doc['source_sha'])
    if doc['schema'] != 1 or sha(doc['artifact_sha']) != sha(expected) or type(doc['upstream_updated']) is not bool:
        raise ValueError('source run / snapshot identity mismatch')
    if doc['ref'] != f'refs/gnu-cross-candidate/{source}':
        raise ValueError('unexpected bundle ref')
    subprocess.run(['git','bundle','verify',str(dest/'candidate.bundle')],check=True,stdout=sys.stderr)
    git('fetch','--no-tags',str(dest/'candidate.bundle'),doc['ref'])
    if git('rev-parse','FETCH_HEAD') != source:
        raise ValueError('bundle source mismatch')
    link = git('ls-tree',source,'builder').split()
    if link[:2] != ['160000','commit'] or link[2] != sha(doc['ctng_commit']):
        raise ValueError('builder gitlink does not match accepted lock')
    for name in ('config','versions'):
        if hashlib.sha256(git_bytes(source,f'{TARGET}/{name}')).hexdigest() != doc['files'][name]:
            raise ValueError('snapshot metadata mismatch')
    if doc['upstream_updated']:
        if git('rev-list','--parents','-n','1',source) != source:
            raise ValueError('candidate must have no parents')
        if git('show','-s','--format=%an <%ae>%n%cn <%ce>%n%B',source) != f'{IDENTITY}\n{IDENTITY}\nfirst commit':
            raise ValueError('invalid root identity or message')
    git('checkout','--detach',source)
    emit(source_sha=source,upstream_updated=doc['upstream_updated'],upstream_versions=version_summary())
    print(source)


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'run': source_run()
        elif sys.argv[1] == 'prepare': prepare(sys.argv[2],sys.argv[3] == 'true')
        elif sys.argv[1] == 'restore': restore(sys.argv[2],sys.argv[3])
        else: raise ValueError('unsupported source command')
    except (ValueError, KeyError, IndexError, TypeError, OSError, subprocess.CalledProcessError) as exc:
        print(f'SOURCE_PREFLIGHT_FAILED: {exc}',file=sys.stderr)
        sys.exit(1)
