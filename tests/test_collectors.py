import importlib.util
from pathlib import Path
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


if __name__ == '__main__':
    unittest.main()
