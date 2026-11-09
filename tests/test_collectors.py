import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


claude = module('claude_usage', 'native/claude_usage.py')
bridge = module('bridge', 'bridge.py')
native_refresh = module('native_refresh', 'native/native_refresh.py')


class ClaudeReads(unittest.TestCase):
    def setUp(self):
        self.good = {'rate_limits_available': True, 'rate_limits': {'five_hour': {'utilization': 12}}, 'subscription_type': 'test'}

    def test_temporary_unavailable_response_recovers_without_login_error(self):
        with patch.object(claude, 'organization', return_value='synthetic-org'), \
             patch.object(claude, 'read_usage', side_effect=[{'rate_limits_available': False}, self.good]) as read, \
             patch.object(claude.time, 'sleep'):
            self.assertTrue(claude.collect_usage(ROOT)['ok'])
            self.assertEqual(read.call_count, 2)

    def test_timeout_retries_once_then_reports_failure(self):
        with patch.object(claude, 'organization', return_value='synthetic-org'), \
             patch.object(claude, 'read_usage', side_effect=claude.UsageUnavailable('timeout')) as read, \
             patch.object(claude.time, 'sleep'):
            with self.assertRaises(claude.UsageUnavailable):
                claude.collect_usage(ROOT)
            self.assertEqual(read.call_count, 2)

    def test_missing_account_does_not_launch_collector(self):
        with patch.object(claude, 'organization', return_value=None), patch.object(claude, 'read_usage') as read:
            with self.assertRaisesRegex(RuntimeError, 'account is unknown'):
                claude.collect_usage(ROOT)
            read.assert_not_called()

    def test_missing_account_has_explicit_auth_code(self):
        with patch.object(claude, 'organization', return_value=None):
            with self.assertRaises(claude.AuthenticationRequired) as failure:
                claude.collect_usage(ROOT)
            self.assertEqual(failure.exception.code, 'auth_required')

    def test_account_switch_cannot_attach_result_to_another_account(self):
        with patch.object(claude, 'organization', side_effect=['synthetic-a', 'synthetic-b']), \
             patch.object(claude, 'read_usage', return_value=self.good):
            with self.assertRaisesRegex(RuntimeError, 'account changed'):
                claude.collect_usage(ROOT)


class CodexHistory(unittest.TestCase):
    def fresh(self, account='synthetic-a', reset=18000):
        raw = {'rateLimits': {'primary': {'usedPercent': 20, 'windowDurationMins': 300, 'resetsAt': reset}}}
        return bridge.normalize(raw, 7200, account)

    def test_history_is_separate_for_new_account_and_new_cycle(self):
        old = bridge.merge({}, self.fresh())
        old['windows'][0]['points'].insert(0, {'t': 3600, 'remaining': 90})
        self.assertEqual(len(bridge.merge(old, self.fresh())['windows'][0]['points']), 2)
        self.assertEqual(len(bridge.merge(old, self.fresh(account='synthetic-b'))['windows'][0]['points']), 1)
        self.assertEqual(len(bridge.merge(old, self.fresh(reset=36000))['windows'][0]['points']), 1)

    def test_no_meter_and_invalid_meter_are_different_states(self):
        for raw, code in [({}, 'no_limits'), ({'rateLimits': {'primary': {'usedPercent': float('nan'), 'windowDurationMins': 300, 'resetsAt': 18000}}}, 'invalid_data')]:
            with self.assertRaises(bridge.UsageReadError) as failure:
                bridge.normalize(raw, 7200, 'synthetic')
            self.assertEqual(failure.exception.code, code)

    def test_real_zero_and_full_capacity_survive_normalization(self):
        for used, expected in [(100, 0), (0, 100)]:
            raw = {'rateLimits': {'primary': {'usedPercent': used, 'windowDurationMins': 300, 'resetsAt': 18000}}}
            self.assertEqual(bridge.normalize(raw, 7200, 'synthetic')['windows'][0]['remaining'], expected)

    def test_auth_failure_and_recovery_keep_history_but_clear_failure_code(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'state.json'
            old = bridge.merge({}, self.fresh())
            path.write_text(json.dumps(old))
            argv = ['native_refresh', '--state-dir', directory]
            with patch.object(sys, 'argv', argv), patch.object(native_refresh, 'read_account_limits', side_effect=bridge.UsageReadError('auth_required', 'synthetic sign-in required')), patch('builtins.print'):
                self.assertEqual(native_refresh.main(), 1)
            failed = json.loads(path.read_text())
            self.assertEqual(failed['errorCode'], 'auth_required')
            self.assertEqual(failed['windows'], old['windows'])
            with patch.object(sys, 'argv', argv), patch.object(native_refresh, 'read_account_limits', return_value=self.fresh()), patch('builtins.print'):
                self.assertEqual(native_refresh.main(), 0)
            recovered = json.loads(path.read_text())
            self.assertIsNone(recovered['errorCode'])
            self.assertIsNone(recovered['error'])


if __name__ == '__main__':
    unittest.main()
