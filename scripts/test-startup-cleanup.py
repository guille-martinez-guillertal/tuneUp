#!/usr/bin/env python3
"""Exercise the cleanup state machine in a temporary fake Mac filesystem.

Only a rewritten test copy executes: macOS tools, /Library paths, and HOME are
redirected to a fixture. These tests do not establish real launchctl behavior.
"""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('Clean-Unused-Startup.command')

class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='tuneup-cleanup-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'home'
        self.bin = self.root / 'bin'
        self.bin.mkdir(); self.home.mkdir()
        for folder in ['Library/LaunchAgents', 'Library/LaunchDaemons', 'Library/Application Support', 'Applications']:
            (self.root / folder).mkdir(parents=True, exist_ok=True)
        (self.home / 'Library/LaunchAgents').mkdir(parents=True)
        self.loaded = self.root / 'loaded'
        self.loaded.write_text('')
        self.stub('uname', 'echo Darwin')
        self.stub('id', 'echo 501')
        self.stub('sudo', 'if [[ "${1:-}" == -v ]]; then exit 0; fi\nexec "$@"')
        self.stub('profiles', 'echo "Enrolled via DEP: No"; echo "MDM enrollment: No"')
        self.stub('stat', 'case "$2" in "%u") echo 0;; "%Lp") echo 700;; "%u:%Lp") echo 0:700;; esac')
        self.stub('install', 'for destination in "${@: -1}"; do mkdir -p "$destination"; chmod 700 "$destination"; done\n# Multi-directory install invocation\nfor destination in "$@"; do if [[ "$destination" == /* ]]; then mkdir -p "$destination"; chmod 700 "$destination"; fi; done')
        self.stub('PlistBuddy', 'exec python3 -c \'import plistlib,sys; print(plistlib.load(open(sys.argv[-1], "rb"))["Label"])\' "$@"')
        self.stub('launchctl', '''if [[ "$1" == print ]]; then
  grep -Fxq "$2" "$FIXTURE_LOADED"; exit $?
fi
if [[ "$1" == bootout ]]; then
  if [[ "${FIXTURE_STUCK:-}" == 1 ]]; then exit 5; fi
  label=$(basename "$3" .plist)
  grep -Fxv "$2/$label" "$FIXTURE_LOADED" > "$FIXTURE_LOADED.tmp" || true
  mv "$FIXTURE_LOADED.tmp" "$FIXTURE_LOADED"
fi''')
        source = SCRIPT.read_text()
        source = source.replace('if [[ "$EUID" -eq 0 ]]; then', 'if false; then')
        for binary in ['uname', 'id', 'sudo', 'profiles', 'stat', 'install']:
            source = source.replace('/usr/bin/' + binary, str(self.bin / binary))
        source = source.replace('/usr/libexec/PlistBuddy', str(self.bin / 'PlistBuddy'))
        source = source.replace('/bin/launchctl', str(self.bin / 'launchctl'))
        source = source.replace("'/Library/", "'" + str(self.root) + '/Library/')
        source = source.replace(' /Applications/', ' ' + str(self.root) + '/Applications/')
        source = source.replace("'/Applications/", "'" + str(self.root) + '/Applications/')
        self.script = self.root / 'cleanup.command'
        self.script.write_text(source)
        self.env = dict(os.environ, HOME=str(self.home), FIXTURE_LOADED=str(self.loaded))

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + body + '\n'); path.chmod(0o755)

    def agent(self, location, name, label=None):
        base = self.home if location == 'user' else self.root
        folder = 'Library/LaunchDaemons' if location == 'daemon' else 'Library/LaunchAgents'
        path = base / folder / (name + '.plist')
        path.write_bytes(plistlib.dumps({'Label': label or name, 'Program': '/nonexistent/test'}))
        return path

    def run_script(self, *args, answer='CLEAN\n'):
        result = subprocess.run(['bash', str(self.script), *args], input=answer, env=self.env, text=True, capture_output=True, timeout=10)
        return result

    def test_preview_and_cancellation_change_nothing(self):
        path = self.agent('user', 'com.skype.skype.shareagent')
        result = self.run_script('--preview')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ARCHIVE:', result.stdout)
        self.assertTrue(path.exists())
        result = self.run_script('--apply', answer='NO\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(path.exists())
        self.assertFalse((self.root / 'Library/Application Support/TuneUp').exists())

    def test_apply_unloads_archives_and_restore_is_repeatable(self):
        path = self.agent('user', 'com.skype.skype.shareagent')
        keep = self.agent('system', 'com.microsoft.update.agent')
        data = path.read_bytes()
        self.loaded.write_text('gui/501/com.skype.skype.shareagent\n')
        result = self.run_script('--apply')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(path.exists())
        self.assertTrue(keep.exists())
        self.assertEqual(self.loaded.read_text(), '')
        backup_id = result.stdout.split('Backup ID: ')[1].splitlines()[0]
        backup = self.root / 'Library/Application Support/TuneUp/StartupBackups' / backup_id
        self.assertEqual((backup / 'user-agents' / path.name).read_bytes(), data)
        second = self.run_script('--apply')
        self.assertIn('Nothing changed', second.stdout)
        restored = self.run_script('--restore', backup_id, answer='RESTORE\n')
        self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr)
        self.assertEqual(path.read_bytes(), data)
        again = self.run_script('--restore', backup_id, answer='RESTORE\n')
        self.assertEqual(again.returncode, 1)  # Never overwrite an existing file.
        self.assertEqual(path.read_bytes(), data)

    def test_loaded_service_failure_keeps_original(self):
        path = self.agent('daemon', 'com.adobe.ARMDC.Communicator')
        self.loaded.write_text('system/com.adobe.ARMDC.Communicator\n')
        self.env['FIXTURE_STUCK'] = '1'
        result = self.run_script('--apply')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue(path.exists())
        self.assertIn('still loaded', result.stdout)

    def test_app_enrollment_label_and_symlink_guards(self):
        sony = self.agent('system', 'com.sony.SonyAutoLauncher.agent')
        (self.root / 'Applications/PMHMac.app').mkdir()
        portal = self.agent('system', 'com.microsoft.entraidentitybrokerxpc')
        self.stub('profiles', 'echo "MDM enrollment: Yes"')
        mismatch = self.agent('user', 'com.adobe.AAM.Updater-1.0', label='unexpected.service')
        skype = self.home / 'Library/LaunchAgents/com.skype.skype.shareagent.plist'
        skype.symlink_to(mismatch)
        result = self.run_script('--apply')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue(sony.exists()); self.assertTrue(portal.exists()); self.assertTrue(mismatch.exists())
        self.assertTrue(skype.is_symlink())
        self.assertIn('unexpected or unreadable', result.stdout)
        self.assertIn('SKIP (symlink)', result.stdout)

    def test_restore_rejects_path_traversal(self):
        result = self.run_script('--restore', '../../elsewhere', answer='RESTORE\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('exact backup ID', result.stderr)

if __name__ == '__main__':
    unittest.main(verbosity=2)
