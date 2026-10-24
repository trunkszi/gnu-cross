#!/usr/bin/env python3
"""Offline package, container and runtime boundary scenarios; no host installation."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TARGET = 'x86_64-unknown-linux-gnu'


def executable(path, text):
    path.write_text('#!/usr/bin/env bash\nset -euo pipefail\n' + text)
    path.chmod(0o755)


class RuntimeGuards(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.stub = self.base/'stub'; self.stub.mkdir()
        self.env = dict(os.environ, PATH=str(self.stub)+':'+os.environ['PATH'])

    def tearDown(self): self.tmp.cleanup()

    def test_package_failures_stop_inside_if_and_preserve_successful_state(self):
        source = (ROOT/'scripts/make').read_text()
        functions = source[source.index('run_package_update() {'):source.index('install_dependencies() {')]
        prefix = '''set -euo pipefail
SUDO_CMD=''
PKG_MANAGER=dnf
PACKAGES=(original)
MIRROR_SETUP_COMMANDS=()
EXTRA_SETUP_COMMANDS=()
USE_GCC10=false
timeout() { shift; "$@"; }
pkg_prepare() { PACKAGES+=(selected); USE_GCC10=true; }
pkg_extra() { echo extra; }
'''
        prefix += 'SCRIPT_DIR='+str(ROOT/'scripts')+'\n'+functions
        cases = [
            ('metadata42', 'dnf() { if [[ $1 == check-update ]]; then return 42; fi; echo INSTALL_BUG; }', False),
            ('preparefalse', 'pkg_prepare() { false; echo PREPARE_BUG; }; dnf() { echo INSTALL_BUG; }', False),
            ('install42', 'dnf() { if [[ $1 == install ]]; then return 42; fi; }; pkg_extra() { echo EXTRA_BUG; }', False),
            ('extra_false', 'dnf() { :; }; pkg_extra() { false; echo EXTRA_BUG; }', False),
            ('update100', 'dnf() { if [[ $1 == check-update ]]; then return 100; fi; }', True),
            ('update0', 'dnf() { :; }', True)]
        for name, body, success in cases:
            with self.subTest(name=name):
                script = prefix+body+'''
if install_dependencies_once; then
 [[ ${PACKAGES[*]} == 'original selected' && $USE_GCC10 == true ]]
 echo SUCCESS
else echo REJECTED; fi
'''
                result = subprocess.run(['bash','-c',script],env=self.env,text=True,capture_output=True)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertNotIn('_BUG',result.stdout)
                self.assertIn('SUCCESS' if success else 'REJECTED',result.stdout)

    def test_optional_compiler_discovery_propagates_errors(self):
        for host in ['amazonlinux2','rhel']:
            for status,expected in [(0,0),(1,0),(42,42),(124,124)]:
                with self.subTest(host=host,status=status):
                    script='set -euo pipefail\nsource "$1"\ntimeout() { return "$2"; }\npkg_prepare\n'
                    # Functions receive their own arguments, so embed the controlled status.
                    script=script.replace('return "$2"',f'return {status}')
                    result=subprocess.run(['bash','-c',script,'test',str(ROOT/'scripts/packages'/f'{host}.conf')],env=self.env,capture_output=True)
                    self.assertEqual(result.returncode,expected)

    def test_docker_allowlist_and_cleanup_of_only_its_own_unique_container(self):
        log = self.base/'docker.jsonl'
        executable(self.stub/'docker', '''python3 - "$@" <<'END'
import json,os,sys
with open(os.environ['DOCKER_LOG'],'a') as f:f.write(json.dumps(sys.argv[1:])+'\\n')
END
if [[ $1 == exec ]]; then exit 42; fi
''')
        self.env['DOCKER_LOG']=str(log)
        for args in [[],[TARGET,'ubuntu:22.04','../escape'],[TARGET,'evil:image','ubuntu22'],[TARGET,'ubuntu:22.04','ubuntu22','extra']]:
            result=subprocess.run(['bash',str(ROOT/'scripts/build-with-docker.sh'),*args],env=self.env,capture_output=True)
            self.assertEqual(result.returncode,64)
        self.assertFalse(log.exists())
        names=[]
        for _ in range(2):
            log.write_text('')
            result=subprocess.run(['bash',str(ROOT/'scripts/build-with-docker.sh'),TARGET,'ubuntu:22.04','ubuntu22'],env=self.env,capture_output=True)
            self.assertEqual(result.returncode,42)
            calls=[json.loads(s) for s in log.read_text().splitlines()]
            run=next(c for c in calls if c[0]=='run'); name=run[run.index('--name')+1];names.append(name)
            self.assertEqual(calls[-1],['rm','-f',name])
            self.assertFalse(any(c[0]=='prune' for c in calls))
        self.assertNotEqual(*names)

    def fixture(self):
        tool=self.base/'tool';sysroot=tool/'sysroot'
        for p in [tool/'bin',tool/TARGET/'bin',tool/'lib',sysroot/'lib',sysroot/'usr/include/gnu']: p.mkdir(parents=True,exist_ok=True)
        self.env.update(TOOL=str(tool),SYSROOT=str(sysroot),RUN_LOG=str(self.base/'executed'))
        compiler='''case "$1" in
-dumpfullversion) echo 16.2.0; exit;;
-print-sysroot) echo "$SYSROOT"; exit;;
-print-file-name=*) name=${1#*=}; if [[ $name == libgcc_s.so.1 && -n ${LEAK_RUNTIME:-} ]]; then echo "$LEAK_RUNTIME"; else echo "$TOOL/lib/$name"; fi; exit;;
esac
compile_args=" $* "
while [[ $# -gt 0 ]]; do if [[ $1 == -o ]]; then output=$2; break; fi; shift; done
if [[ ${REQUIRE_LSAN_PROTECTION:-0} == 1 && $(basename "$output") == lsan ]]; then
 [[ "$compile_args" == *' -fPIE '* && "$compile_args" == *' -pie '* ]] || exit 72
fi
case "$(basename "$output")" in hello-c|hello-mold) answer='C PASS';; hello-cxx) answer='C++ PASS';; *) answer=unused;; esac
printf '#!/usr/bin/env bash\\nprintf "%%s\\n" %q\\n' "$answer" > "$output"
chmod +x "$output"
'''
        for name in ['gcc','g++']:executable(tool/'bin'/f'{TARGET}-{name}',compiler)
        executable(tool/TARGET/'bin/ld.mold','echo mold\n')
        executable(sysroot/'lib/libc.so.6','echo LIBC_EXECUTED >> "$RUN_LOG"\nexit 99\n')
        (sysroot/'usr/include/gnu/libc-version.h').write_text('#define __GLIBC__ 2\n#define __GLIBC_MINOR__ 34\n')
        executable(sysroot/'lib/ld-linux-x86-64.so.2','''echo "$(basename "$3")" >> "$RUN_LOG"
case "$(basename "$3")" in
hello-dynamic) echo 'C PASS';; hello-cxx-dynamic) echo 'C++ PASS';; openmp) echo 2;; quadmath) echo 1.25;;
asan|ubsan|lsan|tsan)
 name=$(basename "$3")
 case "$name" in asan) echo AddressSanitizer;; ubsan) echo 'runtime error';; lsan) echo LeakSanitizer;; tsan) echo 'ThreadSanitizer: data race';; esac
 if [[ $name == lsan && ${REQUIRE_LSAN_PROTECTION:-0} == 1 ]]; then
  [[ ${LSAN_OPTIONS:-} == use_tls=0:use_ld_allocations=0:exitcode=86 ]] || exit 0
 fi
 if [[ ${SANITIZER_ZERO:-} == "$name" ]]; then exit 0; fi
 if [[ ${HANG_CASE:-} == "$name" ]]; then while :; do :; done; fi
 if [[ ${KILL_CASE:-} == "$name" ]]; then kill -KILL $$; fi
 if [[ $name == tsan ]]; then exit 66; else exit 86; fi;;
esac
''')
        for name in ['libgcc_s.so.1','libstdc++.so.6','libgomp.so.1','libquadmath.so.0','libasan.so','libubsan.so','liblsan.so','libtsan.so']:(tool/'lib'/name).touch()
        executable(self.stub/'setarch','shift 2\nexec "$@"\n')
        executable(self.stub/'timeout','''shift
exec /usr/bin/timeout 0.5 "$@"
''')
        return tool,sysroot

    def verify(self,tool,**extra):
        return subprocess.run(['bash',str(ROOT/'scripts/verify-toolchain.sh'),TARGET,str(tool),'16.2.0','2.34'],
                              env=dict(self.env,**extra),text=True,capture_output=True)

    def test_internal_runtime_succeeds_and_real_timeouts_and_kills_fail(self):
        tool,_=self.fixture()
        result=self.verify(tool)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('verification: PASS',result.stdout)
        for name in ['asan','tsan']:
            for mode,status in [('HANG_CASE',124),('KILL_CASE',137)]:
                with self.subTest(name=name,mode=mode):
                    result=self.verify(tool,**{mode:name})
                    self.assertNotEqual(result.returncode,0)
                    self.assertIn(f'({status})',result.stderr)
                    self.assertNotIn('verification: PASS',result.stdout)

    def test_lsan_explicit_loader_uses_pie_and_ignores_loader_roots(self):
        tool,_=self.fixture()
        result=self.verify(tool,REQUIRE_LSAN_PROTECTION='1')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('verification: PASS',result.stdout)

    def test_unexpected_sanitizer_status_preserves_captured_diagnostic(self):
        tool,_=self.fixture()
        result=self.verify(tool,SANITIZER_ZERO='lsan')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('LSan unexpected sanitizer exit 0',result.stderr)
        self.assertIn('LeakSanitizer',result.stderr)

    def test_all_runtime_paths_are_contained_before_libc_execution(self):
        tool,sysroot=self.fixture()
        outside=self.base/'tool-other';outside.mkdir();(outside/'libgcc_s.so.1').touch()
        result=self.verify(tool,LEAK_RUNTIME=str(outside/'libgcc_s.so.1'))
        self.assertNotEqual(result.returncode,0);self.assertIn('host runtime leak',result.stderr)
        # Each symlink injection is isolated so earlier checks cannot mask a later one.
        for relative in ['sysroot','sysroot/lib/libc.so.6','sysroot/lib/ld-linux-x86-64.so.2','sysroot/lib64']:
            with self.subTest(relative=relative):
                path=tool/relative; saved=self.base/'saved'
                existed=path.exists()
                if existed:path.rename(saved)
                path.symlink_to(outside,target_is_directory=True)
                result=self.verify(tool)
                self.assertNotEqual(result.returncode,0)
                self.assertIn('host runtime leak',result.stderr)
                self.assertFalse((self.base/'executed').exists())
                path.unlink()
                if existed:saved.rename(path)

    def test_resolved_kernel_and_binutils_versions_are_checked(self):
        text=(ROOT/'scripts/make').read_text()
        start=text.index('assert_config_value() {')
        end=text.index('\n',text.index('assert_config_value CT_GLIBC_MIN_KERNEL',start))
        fragment=text[start:text.index('\npushd ',start)]+text[text.index('assert_config_value CT_GCC_VERSION',start):end]
        (self.base/'build').mkdir()
        config=self.base/'build/.config'
        env=dict(self.env,EXPECTED_GCC_VERSION='17.1.0',EXPECTED_MOLD_VERSION='2.42.0',EXPECTED_GLIBC_VERSION='2.34',PROJECT_ROOT=str(self.base),EXPECTED_BINUTILS_VERSION='2.47',EXPECTED_LINUX_VERSION='5.4.302')
        good='CT_GCC_VERSION="17.1.0"\nCT_MOLD_VERSION="2.42.0"\nCT_GLIBC_VERSION="2.34"\nCT_BINUTILS_VERSION="2.47"\nCT_LINUX_VERSION="5.4.302"\nCT_GLIBC_MIN_KERNEL="5.4.302"\n'
        for key in ['good','CT_BINUTILS_VERSION','CT_LINUX_VERSION','CT_GLIBC_MIN_KERNEL']:
            config.write_text(good if key=='good' else good.replace(key+'="',key+'="9'))
            result=subprocess.run(['bash','-ec',fragment],cwd=self.base,env=env,text=True,capture_output=True)
            self.assertEqual(result.returncode==0,key=='good',result.stderr)


if __name__=='__main__':unittest.main()
