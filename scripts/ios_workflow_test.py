"""Validate the manual-only workflow and encrypted artifact boundary."""
import json
import subprocess
import unittest
from pathlib import Path


class WorkflowTests(unittest.TestCase):
    def test_workflow_and_shell_steps(self):
        path = Path(__file__).resolve().parents[1] / '.github/workflows/ios-adhoc.yml'
        result = subprocess.run(['ruby', '-r', 'yaml', '-r', 'json', '-e',
                                 'puts JSON.generate(YAML.load_file(ARGV[0]))', str(path)],
                                capture_output=True, check=True, text=True)
        workflow = json.loads(result.stdout)
        # macOS Ruby's YAML 1.1 parser reads "on" as boolean true.
        triggers = workflow.get('on', workflow.get('true'))
        self.assertEqual(set(triggers), {'workflow_dispatch'})
        self.assertTrue(triggers['workflow_dispatch']['inputs']['artifact_recipient']['required'])
        self.assertEqual(workflow['permissions'], {'contents': 'read'})
        steps = workflow['jobs']['signed-ipa']['steps']
        uploads = [s for s in steps if s.get('uses', '').startswith('actions/upload-artifact@')]
        self.assertEqual(len(uploads), 1)
        self.assertEqual(uploads[0]['with']['path'], '${{ runner.temp }}/ios-output/Cochlea.ipa.age')
        self.assertEqual(uploads[0]['with']['retention-days'], 1)
        encrypt = next(s for s in steps if s.get('name') == 'Encrypt IPA')
        self.assertIn('age --encrypt --recipient "$ARTIFACT_RECIPIENT"', encrypt['run'])
        self.assertLess(steps.index(encrypt), steps.index(uploads[0]))
        cleanup = next(s for s in steps if s.get('name') == 'Remove plaintext IPA')
        self.assertEqual(cleanup['if'], 'always()')
        for step in steps:
            if 'run' in step:
                with self.subTest(step=step.get('name')):
                    subprocess.run(['bash', '-n'], input=step['run'], text=True, check=True, capture_output=True)
                    self.assertNotIn('${{', step['run'])
                    self.assertNotIn('set -x', step['run'])
