#!/usr/bin/env python3
"""Offline negative contracts for discovery, source identity and runtime isolation."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RegressionTests(unittest.TestCase):
    def test_malformed_discovery_is_classified_without_metadata_changes(self):
        cases = ['', '{', '{}', '[' * 1100 + '0' + ']' * 1100, '{"tag_name":"v2","draft":0,"prerelease":false}',
                 '{"tag_name":"v2","draft":false}', '{"tag_name":7,"draft":false,"prerelease":false}']
        with tempfile.TemporaryDirectory() as tmp:
            sandbox = Path(tmp)
            shutil.copytree(ROOT / 'scripts', sandbox / 'scripts')
            shutil.copytree(ROOT / 'targets', sandbox / 'targets')
            target = sandbox / 'targets/x86_64-unknown-linux-gnu'
            before = {p.name: p.read_bytes() for p in target.iterdir() if p.is_file()}
            for text in cases:
                with self.subTest(text=text):
                    release = sandbox / 'release.json'
                    release.write_text(text)
                    env = dict(os.environ, UPSTREAM_RELEASE_JSON_FILE=str(release))
                    result = subprocess.run(['bash', str(sandbox/'scripts/sync-upstream.sh'), '--apply'],
                                            env=env, text=True, capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('DISCOVERY_FAILED', result.stdout + result.stderr)
                    self.assertNotIn('Traceback', result.stderr)
                    self.assertEqual(before, {p.name:p.read_bytes() for p in target.iterdir() if p.is_file()})

    def test_bad_ref_and_annotated_tag_schema_are_discovery_failures(self):
        with tempfile.TemporaryDirectory() as tmp:
            sandbox=Path(tmp)
            release=sandbox/'release.json'; release.write_text(json.dumps(dict(tag_name='v2',draft=False,prerelease=False)))
            ref=sandbox/'ref.json'; tag=sandbox/'tag.json'
            for reference,annotation in [({},{}),({'object':{'type':'commit'}},{}),
                ({'object':{'type':'commit','sha':False}},{}),
                ({'object':{'type':'tag','sha':'a'*40}},{}),
                ({'object':{'type':'tag','sha':'a'*40}},{'object':{'type':'commit','sha':None}}),
                ({'object':{'type':'tag','sha':'a'*40}},'{')]:
                with self.subTest(reference=reference,annotation=annotation):
                    ref.write_text(json.dumps(reference))
                    tag.write_text(annotation if isinstance(annotation,str) else json.dumps(annotation))
                    env=dict(os.environ,UPSTREAM_RELEASE_JSON_FILE=str(release),UPSTREAM_REF_JSON_FILE=str(ref),UPSTREAM_TAG_JSON_FILE=str(tag))
                    result=subprocess.run(['bash',str(ROOT/'scripts/sync-upstream.sh'),'--check'],env=env,text=True,capture_output=True)
                    self.assertNotEqual(result.returncode,0)
                    self.assertIn('DISCOVERY_FAILED',result.stdout+result.stderr)
                    self.assertNotIn('Traceback',result.stderr)


if __name__ == '__main__':
    unittest.main()
