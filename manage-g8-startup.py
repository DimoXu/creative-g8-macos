#!/usr/bin/env python3
"""Opt-in login startup and abnormal-exit recovery for the installed G8 app."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

LABEL = "local.codex.g8-volume-keys.recovery"
DOMAIN = f"gui/{os.getuid()}"
HOME = Path.home()
APP = HOME / "Applications/G8 Volume.app"
AGENT = HOME / f"Library/LaunchAgents/{LABEL}.plist"
BINARY = APP / "Contents/MacOS/G8VolumeKeys"


def configuration(binary, logs):
    return {
        "Label": LABEL,
        "ProgramArguments": [str(binary)],
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 10,
        "LimitLoadToSessionType": "Aqua",
        "ProcessType": "Interactive",
        "StandardOutPath": str(logs / "stdout.log"),
        "StandardErrorPath": str(logs / "stderr.log"),
    }


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True)


def loaded():
    return subprocess.run(["launchctl", "print", f"{DOMAIN}/{LABEL}"],
                          text=True, capture_output=True)


def unload():
    if loaded().returncode == 0:
        run("launchctl", "bootout", f"{DOMAIN}/{LABEL}")


def installed_pids():
    matches = subprocess.run(["pgrep", "-u", str(os.getuid()), "-x", "G8VolumeKeys"],
                             text=True, capture_output=True)
    if matches.returncode not in (0, 1):
        raise RuntimeError(f"Cannot inspect running application: {matches.stderr}")
    pids = []
    for pid in matches.stdout.split():
        command = subprocess.run(["ps", "-p", pid, "-o", "comm="], text=True, capture_output=True)
        if command.returncode == 0 and command.stdout.strip() == str(BINARY):
            pids.append(int(pid))
    return pids


def stop_installed_app():
    for pid in installed_pids():
        try:
            os.kill(pid, 15)
        except ProcessLookupError:
            continue
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("Installed app did not exit; startup installation stopped")


def write_agent(data):
    with tempfile.NamedTemporaryFile(dir=AGENT.parent, delete=False) as staged:
        temporary = Path(staged.name)
        try:
            staged.write(data)
            staged.flush()
            temporary.chmod(0o600)
            temporary.replace(AGENT)
        finally:
            temporary.unlink(missing_ok=True)


def install():
    if not BINARY.is_file():
        raise RuntimeError(f"Install the application first: {APP}")
    run("codesign", "--verify", "--strict", str(APP))
    info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "local.codex.g8-volume-keys":
        raise RuntimeError("Unexpected application identity")
    logs = HOME / "Library/Logs/G8VolumeKeys"
    logs.mkdir(parents=True, exist_ok=True, mode=0o700)
    AGENT.parent.mkdir(parents=True, exist_ok=True)
    previous = AGENT.read_bytes() if AGENT.exists() else None
    was_loaded = loaded().returncode == 0
    if was_loaded and previous is None:
        raise RuntimeError("Loaded service has no saved plist; refusing an unrecoverable replacement")
    was_running = bool(installed_pids())
    if was_loaded and not was_running:
        raise RuntimeError("Recovery is loaded but the application is stopped; run start first, "
                           "or remove the recovery configuration before reinstalling")
    # Validate everything possible before interrupting the working application.
    data = plistlib.dumps(configuration(BINARY, logs))
    try:
        unload()
        stop_installed_app()
        write_agent(data)
        run("plutil", "-lint", str(AGENT))
        run("launchctl", "bootstrap", DOMAIN, str(AGENT))
    except Exception as error:
        try:
            unload()
            if previous is None:
                AGENT.unlink(missing_ok=True)
            else:
                write_agent(previous)
                if was_loaded:
                    run("launchctl", "bootstrap", DOMAIN, str(AGENT))
            if was_running and not was_loaded and not installed_pids():
                run("open", str(APP))
        except Exception as recovery_error:
            raise RuntimeError(f"Install failed: {error}; rollback also failed: {recovery_error}. "
                               f"Open {APP} manually to restore volume-key handling.") from error
        raise
    print(f"Installed: {AGENT}")
    print("Login startup enabled; abnormal exits restart, normal Quit stays stopped.")
    print("Existing application and its code signature were not modified.")


class ConfigurationTests(unittest.TestCase):
    def test_restart_only_abnormal_exit(self):
        config = configuration(Path("/a path/G8VolumeKeys"), Path("/logs"))
        self.assertEqual(config["KeepAlive"], {"SuccessfulExit": False})
        self.assertTrue(config["RunAtLoad"])
        self.assertEqual(config["ThrottleInterval"], 10)
        self.assertNotIn("StartInterval", config)
        self.assertEqual(config["LimitLoadToSessionType"], "Aqua")

    def test_exact_binary_no_shell(self):
        path = Path("/a path/应用.app/Contents/MacOS/G8VolumeKeys")
        config = configuration(path, Path("/logs"))
        self.assertEqual(config["ProgramArguments"], [str(path)])
        self.assertEqual(plistlib.loads(plistlib.dumps(config)), config)
        self.assertNotIn("EnvironmentVariables", config)

    def test_per_user_paths(self):
        self.assertEqual(AGENT.parent, HOME / "Library/LaunchAgents")
        self.assertEqual(BINARY, HOME / "Applications/G8 Volume.app/Contents/MacOS/G8VolumeKeys")
        self.assertEqual(configuration(BINARY, HOME / "Library/Logs/G8VolumeKeys")["StandardErrorPath"],
                         str(HOME / "Library/Logs/G8VolumeKeys/stderr.log"))


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        home = Path(self.directory.name)
        app = home / "Applications/G8 Volume.app"
        binary = app / "Contents/MacOS/G8VolumeKeys"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"test executable")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "local.codex.g8-volume-keys"}))
        self.agent = home / "Library/LaunchAgents/recovery.plist"
        for name, value in {"HOME": home, "APP": app, "BINARY": binary, "AGENT": self.agent}.items():
            patch = mock.patch.object(sys.modules[__name__], name, value)
            patch.start()
            self.addCleanup(patch.stop)
        for name in ("run", "loaded", "unload", "installed_pids", "stop_installed_app"):
            patch = mock.patch.object(sys.modules[__name__], name)
            setattr(self, name, patch.start())
            self.addCleanup(patch.stop)
        self.loaded.return_value = subprocess.CompletedProcess([], 1)
        self.installed_pids.return_value = []

    def test_success_has_private_atomic_plist_and_no_signature_change(self):
        before = BINARY.read_bytes()
        install()
        self.assertEqual(plistlib.loads(self.agent.read_bytes()),
                         configuration(BINARY, HOME / "Library/Logs/G8VolumeKeys"))
        self.assertEqual(self.agent.stat().st_mode & 0o777, 0o600)
        self.assertEqual(BINARY.read_bytes(), before)
        self.run.assert_any_call("launchctl", "bootstrap", DOMAIN, str(self.agent))
        self.assertFalse(any("enable" in call.args for call in self.run.call_args_list))

    def test_failed_bootstrap_restores_loaded_service(self):
        self.agent.parent.mkdir(parents=True)
        previous = plistlib.dumps({"Label": LABEL, "old": True})
        self.agent.write_bytes(previous)
        self.loaded.return_value = subprocess.CompletedProcess([], 0)
        self.installed_pids.return_value = [42]
        self.run.side_effect = [None, None, OSError("bootstrap failed"), None]
        with self.assertRaisesRegex(OSError, "bootstrap failed"):
            install()
        self.assertEqual(self.agent.read_bytes(), previous)
        self.assertEqual(self.run.call_args_list[-1].args,
                         ("launchctl", "bootstrap", DOMAIN, str(self.agent)))

    def test_failed_new_install_reopens_previously_running_app(self):
        self.installed_pids.side_effect = [[42], []]
        self.run.side_effect = [None, None, OSError("bootstrap failed"), None]
        with self.assertRaisesRegex(OSError, "bootstrap failed"):
            install()
        self.assertFalse(self.agent.exists())
        self.run.assert_any_call("open", str(APP))

    def test_stop_failure_is_also_rolled_back(self):
        self.installed_pids.side_effect = [[42], []]
        self.stop_installed_app.side_effect = OSError("stop failed")
        with self.assertRaisesRegex(OSError, "stop failed"):
            install()
        self.run.assert_any_call("open", str(APP))

    def test_invalid_identity_does_not_stop_app(self):
        (APP / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "other"}))
        with self.assertRaisesRegex(RuntimeError, "identity"):
            install()
        self.unload.assert_not_called()
        self.stop_installed_app.assert_not_called()

    def test_missing_saved_plist_leaves_service_untouched(self):
        self.loaded.return_value = subprocess.CompletedProcess([], 0)
        with self.assertRaisesRegex(RuntimeError, "no saved plist"):
            install()
        self.unload.assert_not_called()

    def test_loaded_but_stopped_is_not_restarted_on_failed_reinstall(self):
        self.agent.parent.mkdir(parents=True)
        previous = plistlib.dumps({"Label": LABEL, "RunAtLoad": True})
        self.agent.write_bytes(previous)
        self.loaded.return_value = subprocess.CompletedProcess([], 0)
        with self.assertRaisesRegex(RuntimeError, "application is stopped"):
            install()
        self.unload.assert_not_called()
        self.stop_installed_app.assert_not_called()
        self.assertEqual(self.agent.read_bytes(), previous)

    def test_rollback_failure_is_reported_not_hidden(self):
        self.installed_pids.side_effect = [[42], []]
        self.run.side_effect = [None, None, OSError("bootstrap failed"), OSError("open failed")]
        with self.assertRaisesRegex(RuntimeError, "rollback also failed"):
            install()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "start", "remove", "status", "self-test"])
    args = parser.parse_args()
    if args.action == "install":
        install()
    elif args.action == "start":
        if not AGENT.exists():
            raise RuntimeError("Run install first")
        if loaded().returncode != 0:
            run("launchctl", "bootstrap", DOMAIN, str(AGENT))
        else:
            run("launchctl", "kickstart", f"{DOMAIN}/{LABEL}")
        print("Started managed G8 application")
    elif args.action == "remove":
        unload()
        AGENT.unlink(missing_ok=True)
        print("Removed login startup and recovery; application files were not deleted")
    elif args.action == "status":
        result = loaded()
        print(result.stdout if result.returncode == 0 else "Recovery agent is not loaded", end="\n")
    else:
        unittest.main(argv=[sys.argv[0]], exit=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
