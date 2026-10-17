import copy
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[2] / 'scripts/release.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
COMMIT = 'a' * 40


class FakeGitHub:
    def __init__(self, plan, directory):
        self.plan, self.directory = plan, directory
        self.existing = None
        self.events = []
        self.tag_commit = COMMIT
        self.annotated = False
        self.fail_upload = False
        self.corrupt_upload = False
        self.move_tag_on_upload = False
        self.hide_draft_from_tag = False

    def api(self, endpoint, method='GET', data=None, optional=False):
        if '/git/ref/tags/' in endpoint:
            return {'object': {'type': 'tag' if self.annotated else 'commit', 'sha': self.tag_commit}}
        if '/git/tags/' in endpoint:
            return {'object': {'type': 'commit', 'sha': self.tag_commit}}
        if '/releases/tags/' in endpoint:
            if self.hide_draft_from_tag and self.existing and self.existing['draft']:
                return None
            return copy.deepcopy(self.existing)
        if '?per_page=' in endpoint:
            return [copy.deepcopy(self.existing)] if self.existing else []
        if method == 'POST':
            self.events.append('create-draft')
            self.existing = dict(data, id=1, assets=[], html_url='https://example.test/release')
        if method == 'PATCH':
            self.events.append('publish')
            self.existing.update(data)
        return copy.deepcopy(self.existing)

    def upload(self, tag, files):
        self.events.append('upload')
        if self.fail_upload:
            raise RuntimeError('network unavailable')
        self.existing['assets'] = [dict(name=p.name, state='uploaded', size=p.stat().st_size,
                                        digest=release.digest(p)) for p in files]
        if self.corrupt_upload:
            self.existing['assets'][0]['digest'] = 'sha256:' + '0' * 64
        if self.move_tag_on_upload:
            self.tag_commit = 'b' * 40


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.dist = self.root / 'dist'
        (self.root / 'Resources').mkdir()
        self.info = dict(CFBundleIdentifier='io.local.appdual', CFBundleShortVersionString='0.4.2', CFBundleVersion='8')
        (self.root / 'Resources/Info.plist').write_bytes(plistlib.dumps(self.info))
        self.plan = release.prepare(self.root, 'v0.4.2', self.dist, COMMIT)
        with zipfile.ZipFile(self.dist / self.plan['assets'][0], 'w') as z:
            z.writestr('TwinSpace.app/Contents/Info.plist', plistlib.dumps(self.info))
        with zipfile.ZipFile(self.dist / self.plan['assets'][1], 'w') as z:
            z.writestr('source/Package.swift', '// fixture')
        for name in self.plan['assets'][2:4]:
            (self.dist / name).write_text('fixture documentation')
        self.update_checksums()
        self.github = FakeGitHub(self.plan, self.dist)

    def update_checksums(self):
        (self.dist / 'SHA256SUMS.txt').write_text(''.join(
            release.digest(self.dist / name).removeprefix('sha256:') + '  ' + name + '\n'
            for name in self.plan['assets'][:-1]))

    def test_rejects_invalid_or_mismatched_tags(self):
        for tag in ['v0.4.1', 'v01.4.2', '0.4.2', 'v0.4.2/bad', 'v0.4.2\noutput=value', 'v0.4.2-beta.0']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.prepare(self.root, tag, self.dist, COMMIT)

    def test_prerelease_policy_and_generated_notes(self):
        self.assertTrue(self.plan['prerelease'])
        self.info['CFBundleShortVersionString'] = '1.0.0'
        (self.root / 'Resources/Info.plist').write_bytes(plistlib.dumps(self.info))
        self.assertFalse(release.prepare(self.root, 'v1.0.0', self.dist, COMMIT)['prerelease'])
        self.assertTrue(release.prepare(self.root, 'v1.0.0-rc.1', self.dist, COMMIT)['prerelease'])
        notes = (self.dist / 'release-notes.md').read_text()
        self.assertIn('v1.0.0-rc.1', notes)
        self.assertIn('未经 Apple 公证', notes)
        self.assertIn(COMMIT, notes)

    def test_tag_specific_notes_override_base_notes(self):
        notes = self.root / 'docs/releases'
        notes.mkdir(parents=True)
        (notes / 'v0.4.2.md').write_text('base notes')
        (notes / 'v0.4.2-beta.1.md').write_text('beta notes')
        release.prepare(self.root, 'v0.4.2-beta.1', self.dist, COMMIT)
        self.assertTrue((self.dist / 'release-notes.md').read_text().startswith('beta notes'))

    def test_metadata_is_bound_to_checkout(self):
        with patch.object(release, 'git_commit', return_value=COMMIT):
            self.assertEqual(release.load_plan(self.dist, self.root), self.plan)
        with patch.object(release, 'git_commit', return_value='b' * 40), self.assertRaises(ValueError):
            release.load_plan(self.dist, self.root)

    def test_missing_asset_and_tampering_block_publication(self):
        path = self.dist / 'README.zh-CN.md'
        path.write_text('tampered')
        with self.assertRaises(ValueError):
            release.publish(self.github, self.plan, self.dist)
        path.unlink()
        with self.assertRaises(ValueError):
            release.publish(self.github, self.plan, self.dist)
        self.assertEqual(self.github.events, [])

    def test_installer_version_is_verified_even_with_updated_checksums(self):
        with zipfile.ZipFile(self.dist / self.plan['assets'][0], 'w') as z:
            z.writestr('TwinSpace.app/Contents/Info.plist', plistlib.dumps(dict(self.info, CFBundleShortVersionString='9.0.0')))
        self.update_checksums()
        with self.assertRaises(ValueError):
            release.verify_assets(self.dist, self.plan)

    def test_duplicate_checksum_entry_is_rejected(self):
        manifest = self.dist / 'SHA256SUMS.txt'
        manifest.write_text(manifest.read_text() + manifest.read_text().splitlines()[0] + '\n')
        with self.assertRaises(ValueError):
            release.verify_assets(self.dist, self.plan)

    def test_new_release_is_published_only_after_verified_uploads(self):
        self.github.annotated = True
        release.publish(self.github, self.plan, self.dist)
        self.assertEqual(self.github.events, ['create-draft', 'upload', 'publish'])
        self.assertFalse(self.github.existing['draft'])
        self.assertEqual(self.github.existing['make_latest'], 'false')

    def test_failed_upload_leaves_draft_and_retry_completes(self):
        self.github.fail_upload = True
        with self.assertRaises(RuntimeError):
            release.publish(self.github, self.plan, self.dist)
        self.assertTrue(self.github.existing['draft'])
        self.github.fail_upload = False
        self.github.hide_draft_from_tag = True
        release.publish(self.github, self.plan, self.dist)
        self.assertEqual(self.github.events.count('create-draft'), 1)
        self.assertFalse(self.github.existing['draft'])

    def test_remote_digest_mismatch_keeps_release_unpublished(self):
        self.github.corrupt_upload = True
        with self.assertRaises(ValueError):
            release.publish(self.github, self.plan, self.dist)
        self.assertTrue(self.github.existing['draft'])
        self.assertNotIn('publish', self.github.events)

    def test_rerun_never_replaces_published_assets(self):
        release.publish(self.github, self.plan, self.dist)
        events = list(self.github.events)
        (self.dist / 'README.zh-CN.md').write_text('rebuilt documentation')
        self.update_checksums()
        release.publish(self.github, self.plan, self.dist)
        self.assertEqual(self.github.events, events)

    def test_manual_release_is_not_overwritten(self):
        release.publish(self.github, self.plan, self.dist)
        self.github.existing['body'] = 'Manual release'
        events = list(self.github.events)
        with self.assertRaises(ValueError):
            release.publish(self.github, self.plan, self.dist)
        self.assertEqual(self.github.events, events)

    def test_tag_move_before_or_after_upload_stops_publication(self):
        self.github.tag_commit = 'b' * 40
        with self.assertRaises(ValueError):
            release.publish(self.github, self.plan, self.dist)
        self.assertEqual(self.github.events, [])
        self.github.tag_commit = COMMIT
        self.github.move_tag_on_upload = True
        with self.assertRaises(ValueError):
            release.publish(self.github, self.plan, self.dist)
        self.assertNotIn('publish', self.github.events)

    def test_permission_errors_are_not_treated_as_missing_releases(self):
        result = subprocess.CompletedProcess([], 1, stdout='', stderr='gh: Resource not accessible (HTTP 403)')
        with patch.object(release.subprocess, 'run', return_value=result), self.assertRaises(RuntimeError):
            release.GitHub().api('repos/owner/repo/releases/tags/v1.0.0', optional=True)

    def test_manual_run_cannot_publish(self):
        with patch.object(release, 'load_plan', return_value=self.plan), \
                patch.object(release.sys, 'argv', ['release.py', 'publish']), \
                patch.dict(release.os.environ, {'GITHUB_EVENT_NAME': 'workflow_dispatch'}), \
                patch.object(release, 'publish') as publish, self.assertRaises(ValueError):
            release.main()
        publish.assert_not_called()


if __name__ == '__main__':
    unittest.main()
