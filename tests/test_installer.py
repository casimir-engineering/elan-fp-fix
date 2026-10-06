"""Run with: python3 -m unittest discover -s tests -v.

Bash functions and script entry points run against temporary files and mocked
system commands. No root, package installation, service or PAM changes.
"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="elan-fp-tests-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)

    def bash(self, script, *, source=True, env=None):
        prefix = f"source {shlex.quote(str(ROOT / 'build-driver.sh'))}\n" if source else "set -euo pipefail\n"
        return subprocess.run(
            ["/bin/bash", "-c", prefix + script], text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env={**os.environ, "TEST_DIR": str(self.base), **(env or {})},
        )

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_native_libdirs(self):
        for distro, family, multiarch, rpm_lib, expected in [
            ("fedora", "", "", "lib64", "lib64"),
            ("fedora", "", "", "lib", "lib"),
            ("opensuse-tumbleweed", "suse", "", "lib64", "lib64"),
            ("rocky", "rhel centos fedora", "", "lib64", "lib64"),
            ("ubuntu", "debian", "aarch64-linux-gnu", "", "lib/aarch64-linux-gnu"),
            ("debian", "", "x86_64-linux-gnu", "", "lib/x86_64-linux-gnu"),
            ("debian", "", "arm-linux-gnueabihf", "", "lib/arm-linux-gnueabihf"),
            ("arch", "", "", "", "lib"),
        ]:
            with self.subTest(distro=distro, expected=expected):
                release = self.base / "os-release"
                release.write_text(f'ID={distro}\nID_LIKE="{family}"\n')
                result = self.bash('''
                    rpm() { echo "$RPM_LIB"; }
                    dpkg-architecture() { echo "$MULTIARCH"; }
                    resolve_libdir "$TEST_DIR/os-release"
                ''', env={"RPM_LIB": rpm_lib, "MULTIARCH": multiarch})
                self.assert_ok(result)
                self.assertEqual(result.stdout.strip(), expected)

    def test_debian_gcc_multiarch_fallback(self):
        (self.base / "os-release").write_text("ID=debian\n")
        result = self.bash('''
            command() {
                if [[ "$*" == '-v dpkg-architecture' ]]; then return 1; fi
                builtin command "$@"
            }
            gcc() { echo riscv64-linux-gnu; }
            resolve_libdir "$TEST_DIR/os-release"
        ''')
        self.assert_ok(result)
        self.assertEqual(result.stdout.strip(), "lib/riscv64-linux-gnu")

    def test_invalid_rpm_libdir_fails(self):
        (self.base / "os-release").write_text("ID=fedora\n")
        result = self.bash('rpm() { echo "%{_lib}"; }; resolve_libdir "$TEST_DIR/os-release"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot resolve native RPM libdir", result.stdout)

    def tool_path(self, cxx=None, cxx_status=0):
        tools = self.base / "bin"
        tools.mkdir(exist_ok=True)
        for name in ["git", "meson", "ninja", "gcc", "pkg-config"]:
            tool = tools / name
            tool.write_text("#!/bin/bash\nexit 0\n")
            tool.chmod(0o755)
        if cxx:
            tool = tools / cxx
            tool.write_text(f"#!/bin/bash\nexit {cxx_status}\n")
            tool.chmod(0o755)
        return str(tools)

    def deps(self, path, cxx=""):
        # Source first with the normal PATH, then isolate compiler/tool lookup.
        return self.bash('''
            PATH="$TOOLS"
            if host_deps_missing; then echo missing; else echo complete; fi
        ''', env={"TOOLS": path, "CXX": cxx})

    def test_missing_cpp_compiler_detected(self):
        result = self.deps(self.tool_path())
        self.assert_ok(result)
        self.assertEqual(result.stdout.strip(), "missing")

    def test_supported_cpp_compilers(self):
        for compiler in ["g++", "c++", "clang++"]:
            with self.subTest(compiler=compiler):
                result = self.deps(self.tool_path(compiler))
                self.assert_ok(result)
                self.assertEqual(result.stdout.strip(), "complete")
                (self.base / "bin" / compiler).unlink()

    def test_broken_compiler_and_invalid_cxx_detected(self):
        path = self.tool_path("g++", cxx_status=1)
        self.assertEqual(self.deps(path).stdout.strip(), "missing")
        self.assertEqual(self.deps(path, "missing-cxx").stdout.strip(), "missing")

    def test_cpp_package_by_manager(self):
        for manager, package in [("dnf", "gcc-c++"), ("zypper", "gcc-c++"),
                                 ("apt-get", "g++"), ("pacman", "gcc")]:
            with self.subTest(manager=manager):
                result = self.bash('''
                    checks=0
                    host_deps_missing() { checks=$((checks + 1)); [[ $checks == 1 ]]; }
                    command() {
                        if [[ $1 == -v ]]; then [[ $2 == "$MANAGER" ]]; return; fi
                        builtin command "$@"
                    }
                    dnf() { printf '%s\\n' "$*"; }
                    zypper() { printf '%s\\n' "$*"; }
                    apt-get() { printf '%s\\n' "$*"; }
                    pacman() { printf '%s\\n' "$*"; }
                    install_build_deps
                ''', env={"MANAGER": manager})
                self.assert_ok(result)
                self.assertIn(package, result.stdout.split())
                if manager == "pacman":
                    self.assertNotIn("gcc-c++", result.stdout.split())
                    self.assertNotIn("g++", result.stdout.split())

    def test_build_error_keeps_diagnostic_and_exit_status(self):
        result = self.bash('''
            WORKDIR="$TEST_DIR"
            fail() { echo 'ERROR: Unknown compiler g++'; return 7; }
            run_build_step 'Meson setup' fail
        ''')
        self.assertEqual(result.returncode, 7)
        self.assertIn("Meson setup failed (exit 7)", result.stdout)
        self.assertIn("ERROR: Unknown compiler g++", result.stdout)
        self.assertIn(str(self.base / "build.log"), result.stdout)
        self.assertIn("Unknown compiler", (self.base / "build.log").read_text())

    def test_host_build_does_not_continue_after_failed_setup(self):
        result = self.bash('''
            WORKDIR="$TEST_DIR"
            MESON_ARGS=(--libdir=lib64)
            meson() { echo 'missing C++ compiler'; return 8; }
            ninja() { echo 'unexpected Ninja run'; }
            build_on_host
        ''')
        self.assertEqual(result.returncode, 8)
        self.assertNotIn("unexpected Ninja run", result.stdout)
        self.assertIn("missing C++ compiler", result.stdout)

    def test_docker_uses_host_libdir_and_installs_cpp(self):
        result = self.bash('''
            WORKDIR="$TEST_DIR"
            MESON_ARGS=(--prefix=/usr/local --libdir=lib64 -Ddoc=false)
            docker() { printf '%s\\n' "$@"; }
            build_in_docker
        ''')
        self.assert_ok(result)
        self.assertIn("--libdir=lib64", result.stdout)
        self.assertIn("gcc g++ pkg-config", result.stdout)
        self.assertNotIn("meson setup builddir --prefix=/usr/local --libdir=lib64 -Ddoc=false >/dev/null", result.stdout)

    def activation(self, identity, mapped, query_status=0):
        library = self.base / "libfprint-2.so.2"
        library.write_text("fixture")
        return self.bash('''
            LIBDIR="$TEST_DIR"
            timeout() { echo "$IDENTITY"; return "$QUERY_STATUS"; }
            fprintd_pid() { echo 1234; }
            mapped_libfprint() { printf '%s\\n' "$MAPPED"; }
            verify_activation
        ''', env={"IDENTITY": identity, "MAPPED": mapped, "QUERY_STATUS": str(query_status)})

    def test_activation_requires_driver_identity_and_runtime_path(self):
        patched = str(self.base / "libfprint-2.so.2")
        for identity, mapped, expected_status in [
            ("ElanTech press-type fingerprint sensor", patched, 0),
            ("ElanTech Fingerprint Sensor", patched, 1),
            ("ElanTech press-type fingerprint sensor", "/usr/lib64/libfprint-2.so.2.0.0", 1),
            ("ElanTech press-type fingerprint sensor", patched + " (deleted)", 1),
            ("ElanTech press-type fingerprint sensor", "", 1),
        ]:
            with self.subTest(identity=identity, mapped=mapped):
                result = self.activation(identity, mapped)
                self.assertEqual(result.returncode, expected_status, result.stdout)

    def test_query_failure_does_not_pass_even_with_press_text(self):
        result = self.activation("ElanTech press-type fingerprint sensor", str(self.base / "libfprint-2.so.2"), 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("query failed", result.stdout)

    def test_unreadable_systemd_mapping_fails_activation(self):
        result = self.bash('''
            LIBDIR="$TEST_DIR"
            timeout() { echo 'ElanTech press-type fingerprint sensor'; }
            fprintd_pid() { echo 1234; }
            mapped_libfprint() { return 1; }
            verify_activation
        ''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot read", result.stdout)

    def test_maps_parser_uses_systemd_pid_and_keeps_deleted_marker(self):
        result = self.bash('''
            systemctl() { echo 456; }
            read_privileged() {
                [[ "$2" == /proc/456/maps ]] || return 1
                printf '%s\\n' \\
                    '7f-8f r-xp 0 0 1 /usr/local/lib64/libfprint-2.so.2.0.0 (deleted)' \\
                    '8f-9f r--p 0 0 1 /usr/local/lib64/libfprint-2.so.2.0.0 (deleted)' \\
                    '9f-af r--p 0 0 1 /usr/lib64/libc.so.6'
            }
            mapped_libfprint "$(fprintd_pid)"
        ''')
        self.assert_ok(result)
        self.assertEqual(result.stdout.strip(), "/usr/local/lib64/libfprint-2.so.2.0.0 (deleted)")

    def install_fixture(self):
        prefix = self.base / "usr/local"
        library = prefix / "lib64/libfprint-2.so.2.0.0"
        stage = Path(str(self.base / "work/stage") + str(prefix)) / "lib64"
        stage.mkdir(parents=True)
        (stage / library.name).write_text("patched")
        (stage / library.name).chmod(0o755)
        (stage / "libfprint-2.so.2").symlink_to(library.name)
        # Migration fixture: previous installer used a Debian path on Fedora.
        legacy = prefix / "lib/x86_64-linux-gnu/libfprint-2.so.2"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("old")
        manifest = prefix / "share/elan-fp-fix/driver-manifest.txt"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(str(legacy) + "\n")
        return prefix, library, stage, legacy, manifest

    FIXTURE_VARS = '''
        PREFIX="$TEST_DIR/usr/local"
        LIBDIR="$PREFIX/lib64"
        MANIFEST_DIR="$PREFIX/share/elan-fp-fix"
        MANIFEST="$MANIFEST_DIR/driver-manifest.txt"
        WORKDIR="$TEST_DIR/work"
        LOADER_CONF="$TEST_DIR/etc/ld.so.conf.d/00-elan-fp-fix.conf"
        restorecon() { printf '%s\\n' "$@" >>"$TEST_DIR/relabel.txt"; }
    '''

    def test_install_migrates_libdir_and_restores_only_project_paths(self):
        prefix, library, stage, legacy, manifest = self.install_fixture()
        os.setxattr(stage / library.name, b"user.elan-test", b"temporary metadata")
        unrelated = prefix / "lib64/unrelated.so"
        unrelated.parent.mkdir(parents=True)
        unrelated.write_text("keep")
        result = self.bash(self.FIXTURE_VARS + 'install_staged_files\ninstall_staged_files')
        self.assert_ok(result)
        self.assertEqual(library.read_text(), "patched")
        self.assertTrue((library.parent / "libfprint-2.so.2").is_symlink())
        self.assertEqual(library.stat().st_mode & 0o777, 0o755)
        self.assertNotIn("user.elan-test", os.listxattr(library))
        self.assertFalse(legacy.exists())
        self.assertEqual(unrelated.read_text(), "keep")
        labels = (self.base / "relabel.txt").read_text().splitlines()
        self.assertIn(str(library), labels)
        self.assertIn(str(library.parent / "libfprint-2.so.2"), labels)
        self.assertNotIn(str(unrelated), labels)
        self.assertNotIn(str(prefix), labels)
        self.assertNotIn("-R", labels)
        loader = self.base / "etc/ld.so.conf.d/00-elan-fp-fix.conf"
        self.assertEqual(loader.read_text().splitlines()[-1], str(library.parent))
        self.assertIn(str(loader), manifest.read_text())
        self.assertNotIn(str(legacy), manifest.read_text())

    def test_uninstall_twice_removes_managed_files_and_keeps_prints(self):
        _, library, _, legacy, manifest = self.install_fixture()
        prints = self.base / "prints"
        prints.write_text("enrolled")
        result = self.bash(self.FIXTURE_VARS + '''
            restart_fprintd() { echo restarted; }
            install_staged_files
            do_uninstall
            do_uninstall
        ''')
        self.assert_ok(result)
        self.assertFalse(library.exists())
        self.assertFalse(legacy.exists())
        self.assertFalse(manifest.exists())
        self.assertFalse((self.base / "etc/ld.so.conf.d/00-elan-fp-fix.conf").exists())
        self.assertEqual(prints.read_text(), "enrolled")
        self.assertEqual(result.stdout.count("restarted"), 2)  # one command and one status

    def test_unowned_loader_config_is_not_overwritten(self):
        self.install_fixture()
        loader = self.base / "etc/ld.so.conf.d/00-elan-fp-fix.conf"
        loader.parent.mkdir(parents=True)
        loader.write_text("user-owned\n")
        result = self.bash(self.FIXTURE_VARS + "install_staged_files")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(loader.read_text(), "user-owned\n")

    def test_unsafe_manifest_rejected_before_removal(self):
        prefix = self.base / "usr/local"
        manifest = prefix / "share/elan-fp-fix/driver-manifest.txt"
        manifest.parent.mkdir(parents=True)
        unrelated = self.base / "keep"
        unrelated.write_text("keep")
        manifest.write_text(str(unrelated) + "\n")
        result = self.bash(self.FIXTURE_VARS + "do_uninstall")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(unrelated.read_text(), "keep")
        self.assertIn("unsafe driver manifest", result.stdout)

    def test_missing_restorecon_is_a_noop(self):
        self.install_fixture()
        result = self.bash(self.FIXTURE_VARS + '''
            command() {
                if [[ "$*" == '-v restorecon' ]]; then return 1; fi
                builtin command "$@"
            }
            install_staged_files
        ''')
        self.assert_ok(result)
        self.assertFalse((self.base / "relabel.txt").exists())

    def test_restorecon_failure_is_fatal_and_leaves_uninstall_manifest(self):
        _, library, _, _, manifest = self.install_fixture()
        result = self.bash(self.FIXTURE_VARS + '''
            restorecon() { echo 'relabel denied'; return 4; }
            install_staged_files
        ''')
        self.assertEqual(result.returncode, 4, result.stdout)
        self.assertTrue(manifest.exists())
        self.assertIn(str(library), manifest.read_text())

    def test_ldconfig_failure_prevents_service_restart(self):
        result = self.bash('''
            ldconfig() { return 6; }
            systemctl() { echo 'unexpected restart'; }
            if restart_fprintd; then exit 0; else exit $?; fi
        ''')
        self.assertEqual(result.returncode, 6)
        self.assertNotIn("unexpected restart", result.stdout)

    def test_full_installer_enables_pam_only_after_success(self):
        # Copy the real wrapper but supply harmless child scripts and a mock
        # root EUID in the test copy, so this works for ordinary users too.
        wrapper = (ROOT / "install.sh").read_text().replace('"$EUID" -ne 0', '0 -ne 0')
        (self.base / "install.sh").write_text(wrapper)
        for name, text in [
            ("setup-system.sh", '#!/bin/bash\necho "setup $*" >>"$CALLS"\n'),
            ("build-driver.sh", '#!/bin/bash\necho driver >>"$CALLS"\nexit "$DRIVER_STATUS"\n'),
        ]:
            child = self.base / name
            child.write_text(text)
            child.chmod(0o755)
        for status in [1, 0]:
            with self.subTest(driver_status=status):
                calls = self.base / f"calls-{status}"
                result = self.bash('/bin/bash "$TEST_DIR/install.sh"', source=False,
                                   env={"CALLS": str(calls), "DRIVER_STATUS": str(status)})
                self.assertEqual(result.returncode, status, result.stdout)
                expected = ["setup --silent --no-pam", "driver"]
                if status == 0:
                    expected.append("setup --silent --pam-only")
                self.assertEqual(calls.read_text().splitlines(), expected)


if __name__ == "__main__":
    unittest.main()
