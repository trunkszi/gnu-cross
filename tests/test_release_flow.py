#!/usr/bin/env python3
"""Exercise workflow shell boundaries and real candidate Git objects offline."""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT/'.github/workflows/release.yaml').read_text()
REAL_GIT = shutil.which('git')


def step(name):
    lines=WORKFLOW.splitlines()
    start=lines.index('      - name: '+name)
    run=next(i for i in range(start+1,len(lines)) if lines[i].startswith('        run:'))
    if lines[run] != '        run: |': return lines[run].split('run:',1)[1].strip()+'\n'
    body=[]
    for line in lines[run+1:]:
        if line.startswith('          '):body.append(line[10:])
        elif not line.strip():body.append('')
        else:break
    return '\n'.join(body)+'\n'


class ReleaseFlow(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.base=Path(self.tmp.name)
        self.repo=self.base/'repo';self.repo.mkdir()
        for name in ['scripts','targets','.github']:shutil.copytree(ROOT/name,self.repo/name)
        for name in ['README.md','.gitmodules','.gitignore']:
            if (ROOT/name).is_file():shutil.copyfile(ROOT/name,self.repo/name)
        (self.repo/'builder').mkdir()
        self.env=dict(os.environ,GIT_AUTHOR_NAME='Fixture',GIT_AUTHOR_EMAIL='fixture@example.invalid',
                      GIT_COMMITTER_NAME='Fixture',GIT_COMMITTER_EMAIL='fixture@example.invalid',
                      GITHUB_REPOSITORY='fixture/gnu-cross',GITHUB_OUTPUT=str(self.base/'output'),
                      TAG='v0.0.1',SOURCE_RUN_ID='')
        self.git('init','-q')
        self.git('add','-A')
        self.lock=dict(line.split('=',1) for line in (self.repo/'targets/x86_64-unknown-linux-gnu/versions').read_text().splitlines() if '=' in line)
        self.git('update-index','--add','--cacheinfo',f'160000,{self.lock["CTNG_COMMIT"]},builder')
        tree=self.git('write-tree')
        self.original=self.git('commit-tree',tree,'-m','fixture base')
        self.git('update-ref','refs/heads/main',self.original)
        self.git('symbolic-ref','HEAD','refs/heads/main')
        self.env['GITHUB_SHA']=self.original
        self.env['ARTIFACT_SHA']=self.original

    def tearDown(self):self.tmp.cleanup()

    def git(self,*args,cwd=None):
        return subprocess.check_output([REAL_GIT,*args],cwd=cwd or self.repo,env=self.env,stderr=subprocess.DEVNULL).decode().strip()

    def run_script(self,name,*args,cwd=None,env=None):
        return subprocess.run(['python3',str(ROOT/'scripts'/name),*map(str,args)],cwd=cwd or self.repo,
                              env=env or self.env,capture_output=True,text=True)

    def candidate(self):
        self.accepted='b'*40 if self.lock['CTNG_COMMIT']!='b'*40 else 'c'*40
        target=self.repo/'targets/x86_64-unknown-linux-gnu'
        text=(target/'versions').read_text().replace(self.lock['CTNG_COMMIT'],self.accepted)
        text=text.replace('EXPECTED_GCC_VERSION='+self.lock['EXPECTED_GCC_VERSION'],'EXPECTED_GCC_VERSION=17.1.0')
        text=text.replace('EXPECTED_MOLD_VERSION='+self.lock['EXPECTED_MOLD_VERSION'],'EXPECTED_MOLD_VERSION=2.42.0')
        (target/'versions').write_text(text)
        config=(target/'config').read_text()
        config=re.sub(r'^CT_GCC_V_.*=y$','CT_GCC_V_17=y',config,flags=re.M)
        config=re.sub(r'^CT_MOLD_V_.*=y$','CT_MOLD_V_2_42_0=y',config,flags=re.M)
        (target/'config').write_text(config)
        self.source=self.base/'source'
        result=self.run_script('source-snapshot.py','prepare',self.source,'true')
        self.assertEqual(result.returncode,0,result.stderr)
        self.sha=result.stdout.strip()
        self.assertRegex(self.sha,r'^[0-9a-f]{40}$')
        self.assertEqual(self.git('rev-list','--parents','-n','1',self.sha),self.sha)
        self.assertEqual(self.git('show','-s','--format=%an <%ae>%n%cn <%ce>%n%B',self.sha),
                         'Nathan Shea <itzrustz@gmail.com>\nNathan Shea <itzrustz@gmail.com>\nfirst commit')
        self.assertIn(self.accepted,self.git('ls-tree',self.sha,'builder'))
        changes=set(self.git('diff','--name-only',self.original,self.sha).splitlines())
        self.assertLessEqual(changes,{'builder','targets/x86_64-unknown-linux-gnu/config','targets/x86_64-unknown-linux-gnu/versions'})
        self.assertLessEqual({'builder','targets/x86_64-unknown-linux-gnu/versions'},changes)
        self.assertEqual(self.git('rev-parse','HEAD'),self.original)
        self.assertEqual(list((self.repo/'builder').iterdir()),[])

    def restore(self):
        self.candidate()
        self.job=self.base/'job';self.job.mkdir();self.git('init','-q',cwd=self.job)
        shutil.copytree(self.source,self.job/'.candidate-source')
        result=self.run_script('source-snapshot.py','restore',self.job/'.candidate-source',self.original,cwd=self.job)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.git('rev-parse','HEAD',cwd=self.job),self.sha)
        self.assertFalse((self.job/'config').exists())
        self.assertFalse((self.job/'versions').exists())
        self.assertIn('EXPECTED_GCC_VERSION=17.1.0',(self.job/'targets/x86_64-unknown-linux-gnu/versions').read_text())
        self.assertIn('CT_MOLD_V_2_42_0=y',(self.job/'targets/x86_64-unknown-linux-gnu/config').read_text())
        self.assertEqual(list((self.job/'builder').iterdir()),[])

    def assets(self):
        self.restore()
        release=self.job/'release';release.mkdir()
        for host in ['amazonlinux2','alinux3','centos7','ubuntu22']:
            package=release/f'x86_64-unknown-linux-gnu-{host}.tar.xz';package.write_bytes(host.encode())
            import hashlib
            package.with_name(package.name+'.sha256').write_text(hashlib.sha256(package.read_bytes()).hexdigest()+'\n')
            r=self.run_script('release-artifacts.py','record',release,host,cwd=self.job)
            self.assertEqual(r.returncode,0,r.stderr)
        (self.job/'RELEASE.md').write_text('fixture notes\n')

    def stubs(self):
        stub=self.base/'bin';stub.mkdir();calls=self.base/'calls'
        (stub/'git').write_text('''#!/usr/bin/env python3
import json,os,sys
args=sys.argv[1:]
with open(os.environ['CALLS'],'a') as f:f.write(json.dumps(['git',*args])+'\\n')
if args[0]=='push':sys.exit(int(os.environ.get('PUSH_FAIL','0')))
if args[0]=='ls-remote':print(os.environ['ARTIFACT_SHA']+'\\trefs/heads/main');sys.exit(0)
os.execv(os.environ['REAL_GIT'],[os.environ['REAL_GIT'],*args])
''')
        (stub/'gh').write_text('''#!/usr/bin/env python3
import json,os,pathlib,shutil,sys
args=sys.argv[1:]
with open(os.environ['CALLS'],'a') as f:f.write(json.dumps(['gh',*args])+'\\n')
if args[0]=='api':print(os.environ['RUN_RESPONSE']);sys.exit(0)
command=args[1]
if command=='view':sys.exit(int(os.environ.get('NEW_RELEASE','0')))
if command in ('create','upload'):
 if os.environ.get('UPLOAD_FAIL'):sys.exit(42)
 dest=pathlib.Path(os.environ['REMOTE']);dest.mkdir(exist_ok=True)
 for a in args[3:]:
  if pathlib.Path(a).is_file():shutil.copyfile(a,dest/pathlib.Path(a).name)
elif command=='download':
 dest=pathlib.Path(args[args.index('--dir')+1]);dest.mkdir(exist_ok=True)
 for p in pathlib.Path(os.environ['REMOTE']).iterdir():shutil.copyfile(p,dest/p.name)
 if os.environ.get('CORRUPT_REMOTE'):
  p=next(dest.glob('*.tar.xz'));p.write_bytes(b'corrupt')
''')
        for p in stub.iterdir():p.chmod(0o755)
        self.env.update(PATH=str(stub)+':'+os.environ['PATH'],REAL_GIT=REAL_GIT,CALLS=str(calls),REMOTE=str(self.base/'remote'))
        self.calls=calls

    def publish(self,**extra):
        env=dict(self.env,**extra)
        return subprocess.run(['bash','scripts/publish-release.sh'],cwd=self.job,env=env,capture_output=True,text=True)

    def test_candidate_restores_identical_tree_and_gitlink(self):self.restore()

    def test_locked_snapshot_does_not_create_an_unrelated_source_commit(self):
        source=self.base/'locked-source'
        result=self.run_script('source-snapshot.py','prepare',source,'false')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.strip(),self.original)
        doc=json.loads((source/'source.json').read_bytes())
        self.assertFalse(doc['upstream_updated'])
        self.assertEqual(doc['artifact_sha'],self.original)

    def test_workflow_wires_one_snapshot_and_one_source_identity(self):
        self.assertNotIn('upstream-metadata',WORKFLOW)
        self.assertEqual(WORKFLOW.count('name: Download candidate source'),2)
        self.assertEqual(WORKFLOW.count('run: python3 scripts/source-snapshot.py restore .candidate-source "${ARTIFACT_SHA}"'),2)
        self.assertIn('cancel-in-progress: false',WORKFLOW)
        self.assertNotIn('docker system prune',WORKFLOW)
        self.assertIn('run: python3 scripts/source-snapshot.py run',WORKFLOW)
        self.assertEqual(WORKFLOW.count('run-id: ${{ inputs.source_run_id || github.run_id }}'),3)
        env=dict(self.env,EVENT_NAME='workflow_dispatch',INPUT_TARGETS='x86_64-unknown-linux-gnu',INPUT_CONTAINERS='all',SHOULD_BUILD='true')
        result=subprocess.run(['bash','-c',step('Set up matrix')],env=env,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        output=(self.base/'output').read_text().split('matrix=',1)[1].splitlines()[0]
        self.assertEqual(len(json.loads(output)['include']),4)
        for field,value in [('INPUT_TARGETS','../escape'),('INPUT_CONTAINERS','unknown')]:
            result=subprocess.run(['bash','-c',step('Set up matrix')],env=dict(env,**{field:value}),capture_output=True)
            self.assertNotEqual(result.returncode,0)

    def test_restore_rejects_wrong_run_before_checkout(self):
        self.candidate()
        result=self.run_script('source-snapshot.py','restore',self.source,'0'*40)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.git('rev-parse','HEAD'),self.original)

    def test_publication_transfers_exact_root_after_remote_asset_verification(self):
        self.assets();self.stubs()
        result=self.publish()
        self.assertEqual(result.returncode,0,result.stderr)
        calls=[json.loads(s) for s in self.calls.read_text().splitlines()]
        download=next(i for i,c in enumerate(calls) if c[:3]==['gh','release','download'])
        pushes=[(i,c) for i,c in enumerate(calls) if c[:2]==['git','push']]
        self.assertEqual(len(pushes),2)
        self.assertTrue(all(i>download for i,_ in pushes))
        self.assertTrue(any(f'{self.sha}:refs/heads/main' in c for _,c in pushes))
        self.assertTrue(any(f'{self.sha}:refs/tags/v0.0.1' in c for _,c in pushes))

    def test_first_release_targets_existing_artifact_head_then_promotes_root(self):
        self.assets();self.stubs()
        result=self.publish(NEW_RELEASE='1')
        self.assertEqual(result.returncode,0,result.stderr)
        calls=[json.loads(s) for s in self.calls.read_text().splitlines()]
        create=next(c for c in calls if c[:3]==['gh','release','create'])
        self.assertEqual(create[create.index('--target')+1],self.original)

    def test_historical_publication_keeps_main_and_uses_candidate_tag(self):
        self.assets();self.stubs()
        result=self.publish(SOURCE_RUN_ID='123')
        self.assertEqual(result.returncode,0,result.stderr)
        calls=[json.loads(s) for s in self.calls.read_text().splitlines()]
        pushes=[c for c in calls if c[:2]==['git','push']]
        self.assertEqual(len(pushes),1)
        self.assertIn(f'{self.sha}:refs/tags/v0.0.1',pushes[0])

    def test_failed_upload_or_remote_corruption_never_promotes(self):
        self.assets();self.stubs()
        for failure in ['UPLOAD_FAIL','CORRUPT_REMOTE']:
            with self.subTest(failure=failure):
                self.calls.write_text('')
                result=self.publish(**{failure:'1'})
                self.assertNotEqual(result.returncode,0)
                self.assertNotIn('["git", "push"',self.calls.read_text())
                self.assertIn('assets_touched=true',(self.base/'output').read_text())

    def test_four_cells_must_match_the_original_artifact_sha(self):
        self.assets()
        manifest=next((self.job/'release').glob('*.manifest.json'))
        value=json.loads(manifest.read_text());value['artifact_sha']='f'*40;manifest.write_text(json.dumps(value))
        result=self.run_script('release-artifacts.py','verify','release',cwd=self.job)
        self.assertNotEqual(result.returncode,0)

    def test_source_run_status_and_head_are_validated(self):
        self.stubs();self.env['SOURCE_RUN_ID']='123'
        doc=dict(status='completed',conclusion='success',head_sha='a'*40,head_branch='main',event='schedule',
                 path='.github/workflows/release.yaml',repository={'full_name':'fixture/gnu-cross'},head_repository={'full_name':'fixture/gnu-cross'})
        self.env['RUN_RESPONSE']=json.dumps(doc)
        result=self.run_script('source-snapshot.py','run')
        self.assertEqual(result.stdout.strip(),'a'*40)
        self.assertNotEqual(result.stdout.strip(),self.original)
        for field,value in [('status','queued'),('conclusion','failure'),('head_sha',''),('head_branch','topic'),('event','pull_request'),('path','other.yaml')]:
            env=dict(self.env,RUN_RESPONSE=json.dumps(dict(doc,**{field:value})))
            self.assertNotEqual(self.run_script('source-snapshot.py','run',env=env).returncode,0)

    def test_failure_notification_reports_stage_touch_state_versions_and_link(self):
        for prepare,build,release,touched,stage,state in [
            ('failure','skipped','skipped','','UPSTREAM_PREFLIGHT_FAILED','UNTOUCHED'),
            ('success','failure','skipped','','TOOLCHAIN_BUILD_FAILED','UNTOUCHED'),
            ('success','success','failure','false','PUBLICATION_FAILED','UNTOUCHED'),
            ('success','success','failure','true','PUBLICATION_FAILED','PARTIAL_UPDATE_POSSIBLE'),
            ('success','success','failure','','PUBLICATION_FAILED','PARTIAL_UPDATE_POSSIBLE')]:
            summary=self.base/'summary';summary.write_text('')
            env=dict(self.env,PREPARE_RESULT=prepare,BUILD_RESULT=build,RELEASE_RESULT=release,
                     RELEASE_ASSETS_TOUCHED=touched,GITHUB_STEP_SUMMARY=str(summary),GITHUB_RUN_ID='456',
                     UPSTREAM_VERSIONS='GCC 17.1.0; mold 2.42.0',SMTP_HOST='')
            result=subprocess.run(['bash','-c',step('Write failure diagnostic')],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            text=summary.read_text();self.assertIn(stage,text);self.assertIn(state,text)
            self.assertIn('GCC 17.1.0',text);self.assertIn('/actions/runs/456',text)

    def test_smtp_tls_checks_certificate_for_both_modes(self):
        spec=importlib.util.spec_from_file_location('notify',ROOT/'scripts/notify-failure.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        calls=[]
        class SMTP:
            def __init__(self,host,port,**kwargs):
                calls.append(('open',port,kwargs.get('context')))
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def starttls(self,*,context):calls.append(('tls',context))
            def login(self,*args):pass
            def send_message(self,msg):self.msg=msg
        for port in ['465','587']:
            env=dict(SMTP_HOST='fixture',SMTP_PORT=port,SMTP_USERNAME='u',SMTP_PASSWORD='p',NOTIFY_EMAIL_TO='r',
                     FAILURE_STAGE='PUBLICATION_FAILED',PUBLISHED_STATE='PARTIAL_UPDATE_POSSIBLE',UPSTREAM_VERSIONS='fixture',RUN_URL='fixture')
            with patch.dict(os.environ,env),patch.object(module.smtplib,'SMTP',SMTP),patch.object(module.smtplib,'SMTP_SSL',SMTP):module.send()
        contexts=[c[-1] for c in calls if c[-1] is not None]
        self.assertEqual(len(contexts),2)
        self.assertTrue(all(c.verify_mode==ssl.CERT_REQUIRED and c.check_hostname for c in contexts))


if __name__=='__main__':unittest.main()
