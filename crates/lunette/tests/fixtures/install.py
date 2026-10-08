import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[4]
ASSETS = (
    'actions.json',
    'bindings_vive_controller.json',
    'bindings_knuckles.json',
    'bindings_oculus_touch.json',
    'bindings_frame_controller.json',
)


class InstallTest(unittest.TestCase):
    def setUp(self):
        target = ROOT / 'target'
        target.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='lunette-install-', dir=target)
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.source = self.base / 'fixture source with spaces'
        self.library = self.source / 'build/linked/out/build/Release'
        self.library.mkdir(parents=True)
        (self.library / 'bin').mkdir()
        self.compile('int support(void) { return 73; }', self.library / 'bin/libsupport.so',
                     '-shared', '-fPIC', '-Wl,-soname,libsupport.so')
        self.compile('extern int support(void); int answer(void) { return support(); }',
                     self.library / 'liblovr.so', '-shared', '-fPIC',
                     '-L' + str(self.library / 'bin'), '-lsupport',
                     '-Wl,-soname,liblovr.so', '-Wl,-rpath,$ORIGIN/bin:$ORIGIN')
        self.compile(
            '#define _GNU_SOURCE\n#include <dlfcn.h>\n#include <stdio.h>\n'
            'extern int answer(void); int main(void) { Dl_info info; '
            'if (!dladdr(answer, &info)) return 2; '
            'printf("%d %s\\n", answer(), info.dli_fname); return 0; }',
            self.source / 'lunette', '-L' + str(self.library), '-llovr', '-ldl',
            '-Wl,-rpath,' + str(self.library) + ':' + str(self.library / 'bin')
            + ':$ORIGIN/../lib/lunette')
        shutil.copy2(self.source / 'lunette', self.source / 'lunctl')
        self.bundle()
        self.cache = self.library.parent / 'CMakeCache.txt'
        self.cache.write_text('LOVR_ENABLE_OPENVR:BOOL=ON\n')
        fake = self.base / 'cargo.py'
        fake.write_text('import shutil, sys\n'
                        'shutil.copytree(sys.argv[1], sys.argv[2], dirs_exist_ok=True)\n')
        self.target = self.base / 'custom target'
        self.build = self.target / 'shipping'
        self.destination = self.base / 'destination with spaces'
        self.installed = self.destination / 'usr/lib/lunette'
        self.command = [
            'make', 'install', 'PROFILE=shipping',
            'CARGO_TARGET_DIR=' + str(self.target),
            'DESTDIR=' + str(self.destination), 'PREFIX=/usr', 'SYSCONFDIR=/etc/config space',
            'CARGO=' + shlex.join(['python3', str(fake), str(self.source), str(self.build)]),
        ]
        self.environment = dict(os.environ)
        for name in ('LD_LIBRARY_PATH', 'LD_PRELOAD', 'MAKEFLAGS', 'MFLAGS'):
            self.environment.pop(name, None)

    def compile(self, text, output, *arguments):
        result = subprocess.run(['cc', '-x', 'c', '-', '-o', str(output), *arguments],
                                input=text, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def bundle(self):
        (self.library / 'lovr-openvr').mkdir(exist_ok=True)
        for name in ASSETS:
            (self.library / 'lovr-openvr' / name).write_text('{}')

    def install(self, succeeds=True):
        result = subprocess.run(self.command, cwd=ROOT, env=self.environment,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)
        return result

    def assert_loaded_installed_library(self):
        for name in ('lunette', 'lunctl'):
            binary = self.destination / 'usr/bin' / name
            result = subprocess.run([str(binary)], env=self.environment,
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            value, library = result.stdout.strip().split(' ', 1)
            self.assertEqual(value, '73')
            self.assertEqual(Path(library).resolve(), self.installed / 'liblovr.so')
            rpath = subprocess.check_output(['patchelf', '--print-rpath', str(binary)],
                                            text=True).strip()
            self.assertEqual(rpath, '$ORIGIN:$ORIGIN/../lib/lunette')

    def test_clean_install_and_stale_artifact_selection(self):
        self.assertFalse(self.build.exists())
        self.install()
        bundle = self.installed / 'lovr-openvr'
        self.assertEqual(bundle.stat().st_mode & 0o777, 0o755)
        self.assertEqual({path.name for path in bundle.iterdir()}, set(ASSETS))
        for name in ASSETS:
            self.assertEqual((bundle / name).stat().st_mode & 0o777, 0o644)
            self.assertEqual((bundle / name).read_text(), '{}')
        self.assertTrue((self.destination / 'etc/config space/xdg/lunette/conf.lua').is_file())
        self.assert_loaded_installed_library()
        stale = self.build / 'build/newer/out/build'
        stale.mkdir(parents=True)
        self.compile('int answer(void) { return 99; }', stale / 'liblovr.so',
                     '-shared', '-fPIC')
        self.install()
        self.assert_loaded_installed_library()
        self.source.rename(self.base / 'inaccessible-source')
        self.build.rename(self.base / 'inaccessible-build')
        self.assert_loaded_installed_library()
        self.assertTrue((self.destination / 'usr/share/lunette/lua/mullion/init.lua').is_file())

    def test_enabled_missing_and_partial_bundles_fail(self):
        (self.library / 'lovr-openvr/actions.json').unlink()
        self.assertIn('enabled OpenVR build has an incomplete action bundle',
                      self.install(False).stderr)
        shutil.rmtree(self.library / 'lovr-openvr')
        shutil.rmtree(self.build)
        self.assertIn('enabled OpenVR build has an incomplete action bundle',
                      self.install(False).stderr)
        self.assertFalse((self.destination / 'usr/bin/lunette').exists())

    def test_disabled_absent_optional_bundle_and_partial_bundle(self):
        self.cache.write_text('LOVR_ENABLE_OPENVR:BOOL=OFF\n')
        shutil.rmtree(self.library / 'lovr-openvr')
        self.install()
        self.assertFalse((self.installed / 'lovr-openvr').exists())
        self.assert_loaded_installed_library()
        self.bundle()
        (self.library / 'lovr-openvr/actions.json').unlink()
        self.assertIn('disabled OpenVR build has an incomplete action bundle',
                      self.install(False).stderr)

    def test_every_partial_bundle_fails_in_both_build_states(self):
        for state in ('ON', 'OFF'):
            self.cache.write_text('LOVR_ENABLE_OPENVR:BOOL=' + state + '\n')
            for asset in ASSETS:
                with self.subTest(state=state, missing=asset):
                    self.bundle()
                    (self.library / 'lovr-openvr' / asset).unlink()
                    if self.build.exists():
                        shutil.rmtree(self.build)
                    result = self.install(False)
                    self.assertIn('incomplete action bundle', result.stderr)
                    self.assertIn(asset + ' is missing', result.stderr)

    def test_unknown_and_missing_build_state_fail(self):
        self.cache.write_text('LOVR_ENABLE_OPENVR:BOOL=invalid\n')
        self.assertIn('cannot determine OpenVR build state', self.install(False).stderr)
        self.cache.unlink()
        shutil.rmtree(self.build)
        self.assertIn('cannot determine OpenVR build state', self.install(False).stderr)

    def test_missing_patchelf_fails(self):
        command = self.command + ['PATCHELF=' + str(self.base / 'missing-patchelf')]
        result = subprocess.run(command, cwd=ROOT, env=self.environment,
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('missing-patchelf', result.stderr)
        self.assertFalse((self.destination / 'usr/bin/lunette').exists())

    def test_patchelf_failure_propagates_before_and_after_copy(self):
        patcher = self.base / 'patcher.py'
        for operation in ('--print-rpath', '--set-rpath'):
            with self.subTest(operation=operation):
                patcher.write_text(
                    'import subprocess, sys\n'
                    'if sys.argv[1] == ' + repr(operation) + ':\n'
                    '    sys.stderr.write("injected patchelf failure\\n")\n'
                    '    sys.exit(19)\n'
                    'sys.exit(subprocess.call(["patchelf", *sys.argv[1:]]))\n')
                command = self.command + ['PATCHELF=' + shlex.join(['python3', str(patcher)])]
                result = subprocess.run(command, cwd=ROOT, env=self.environment,
                                        text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('injected patchelf failure', result.stderr)
                binary = self.destination / 'usr/bin/lunette'
                self.assertEqual(binary.exists(), operation == '--set-rpath')


if __name__ == '__main__':
    unittest.main()
