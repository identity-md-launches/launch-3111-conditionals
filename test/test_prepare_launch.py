"""Offline success/failure tests for the symbol-only review path; all quotes are test fixtures."""

import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr

from tools.prepare_launch import (
    ReviewError, assert_symbol_only, canonical, digest, load, main, prepare_review, update_symbol,
)


ROOT = Path(__file__).resolve().parents[1]
NOW = 2_000_000_000


class LaunchReviewTests(unittest.TestCase):
    def setUp(self):
        self.baseline = load(ROOT / "config/policy-baseline.json")
        self.config_hash = digest(update_symbol(self.baseline))
        self.capabilities = {
            "chainId": 4663,
            "configurationSha256": self.config_hash,
            "exactSymbolSupported": True,
            "acceptedSymbol": "CONDITIONALS",
            "maxSymbolLength": 12,
        }
        self.quote = {
            "quoteId": "local-test-fixture-not-a-live-price",
            "chainId": 4663,
            "configurationSha256": self.config_hash,
            "issuedAt": NOW - 10,
            "expiresAt": NOW + 100,
            "complete": True,
            "components": [
                {"kind": "service", "label": "Test service", "currency": "IMD", "decimals": 18, "amount": "1000000000000000001"},
                {"kind": "funding", "label": "Test funding", "currency": "IMD", "decimals": 18, "amount": "2000000000000000000"},
                {"kind": "gas", "label": "Test network estimate", "currency": "ETH", "decimals": 18, "amount": "1234567890123456"},
            ],
        }

    def review(self, **kwargs):
        args = {"capabilities": self.capabilities, "quote": self.quote, "now": NOW}
        args.update(kwargs)
        return prepare_review(self.baseline, **args)

    def test_exact_symbol_only_and_original_not_mutated(self):
        before = canonical(self.baseline)
        result = self.review()
        self.assertEqual(canonical(self.baseline), before)
        self.assertEqual(result["configuration"]["token"]["symbol"], "CONDITIONALS")
        self.assertEqual(result["symbolLength"], 12)
        self.assertEqual(result["changes"], [{"path": "token.symbol", "before": "CONDITIONAL", "after": "CONDITIONALS"}])
        restored = copy.deepcopy(result["configuration"])
        restored["token"]["symbol"] = "CONDITIONAL"
        self.assertEqual(restored, self.baseline)

    def test_preserves_unknown_fields_fees_permissions_and_recipients(self):
        self.baseline["hook"]["customBehavior"] = {"fee": 173, "nested": ["keep", {"enabled": False}]}
        self.baseline["recipients"]["feeRecipient"] = self.baseline["owner"]
        self.baseline["futureField"] = [None, 11, "11"]
        updated = update_symbol(self.baseline)
        self.assertEqual(updated["hook"], self.baseline["hook"])
        self.assertEqual(updated["recipients"], self.baseline["recipients"])
        self.assertEqual(updated["futureField"], self.baseline["futureField"])
        updated["hook"]["customBehavior"]["nested"].append("new")
        self.assertEqual(len(self.baseline["hook"]["customBehavior"]["nested"]), 2)

    def test_idempotent_when_symbol_already_correct(self):
        result = prepare_review(update_symbol(self.baseline))
        self.assertEqual(result["changes"], [])

    def test_total_cost_is_exact_and_keeps_eth_separate_from_imd(self):
        result = self.review()
        self.assertEqual([item["display"] for item in result["totalCost"]], ["0.001234567890123456 ETH", "3.000000000000000001 IMD"])
        self.assertEqual(result["status"], "awaiting-user-confirmation")
        self.assertTrue(result["confirmationRequired"])
        self.assertFalse(result["broadcastAuthorized"])
        self.assertEqual(result["deployment"]["status"], "not-broadcast")

    def test_missing_system_and_quote_cannot_be_confused_with_zero_cost(self):
        result = prepare_review(self.baseline)
        self.assertIsNone(result["totalCost"])
        self.assertEqual(len(result["missing"]), 2)
        self.assertFalse(result["broadcastAuthorized"])

    def test_shortened_lowercase_padded_or_other_symbol_fails(self):
        for symbol in ("CONDITIONAL", "conditionalS", "CONDITIONALS ", "COND", "ＣＯＮＤＩＴＩＯＮＡＬＳ", ""):
            with self.subTest(symbol=symbol):
                candidate = update_symbol(self.baseline)
                candidate["token"]["symbol"] = symbol
                with self.assertRaises(ReviewError):
                    self.review(candidate=candidate)

    def test_unrelated_configuration_changes_fail(self):
        mutations = [
            ("token", "name", "Changed"), ("token", "totalSupply", "1"),
            ("token", "decimals", 6), ("allocation", "poolBps", 7999),
            ("pool", "fee", 0), ("pool", "tickSpacing", 1),
            ("pool", "pairedCurrency", self.baseline["owner"]),
            ("pool", "initialPrice", "1"), ("hook", "hookFeeBps", 1),
            ("hook", "flags", 16383), ("hook", "pausable", True),
            ("hook", "pausable", 0), ("recipients", "remainder", "another recipient"),
        ]
        for section, key, value in mutations:
            with self.subTest(section=section, key=key, value=value):
                candidate = update_symbol(self.baseline)
                candidate[section][key] = value
                with self.assertRaises(ReviewError):
                    self.review(candidate=candidate)
        for key, value in (("chainId", 1), ("owner", self.baseline["pool"]["pairedCurrency"]), ("extra", True)):
            candidate = update_symbol(self.baseline)
            candidate[key] = value
            with self.assertRaises(ReviewError):
                self.review(candidate=candidate)
        candidate = update_symbol(self.baseline)
        del candidate["recipients"]
        with self.assertRaises(ReviewError):
            self.review(candidate=candidate)

    def test_each_nested_permission_is_preserved(self):
        for permission in self.baseline["hook"]["permissions"]:
            candidate = update_symbol(self.baseline)
            candidate["hook"]["permissions"][permission] = not candidate["hook"]["permissions"][permission]
            with self.subTest(permission=permission), self.assertRaises(ReviewError):
                assert_symbol_only(self.baseline, candidate)

    def test_unsupported_or_truncating_system_stops(self):
        for field, value in (("exactSymbolSupported", False), ("acceptedSymbol", "CONDITIONAL"),
                             ("maxSymbolLength", 11), ("maxSymbolLength", True), ("chainId", 1),
                             ("configurationSha256", "different configuration")):
            capabilities = copy.deepcopy(self.capabilities)
            capabilities[field] = value
            with self.subTest(field=field), self.assertRaises(ReviewError):
                self.review(capabilities=capabilities)

    def test_expired_future_incomplete_or_misbound_quote_fails(self):
        for field, value in (("expiresAt", NOW), ("issuedAt", NOW + 1), ("complete", False),
                             ("chainId", 1), ("configurationSha256", "different configuration"),
                             ("quoteId", ""), ("expiresAt", str(NOW + 1)), ("components", [])):
            quote = copy.deepcopy(self.quote)
            quote[field] = value
            with self.subTest(field=field), self.assertRaises(ReviewError):
                self.review(quote=quote)

    def test_incomplete_and_ambiguous_amounts_fail(self):
        for amount in (-1, 1.2, "-1", "1.2", "1e18", "01", "NaN", None):
            quote = copy.deepcopy(self.quote)
            quote["components"][0]["amount"] = amount
            with self.subTest(amount=amount), self.assertRaises(ReviewError):
                self.review(quote=quote)
        quote = copy.deepcopy(self.quote)
        quote["components"][1]["decimals"] = 6
        with self.assertRaises(ReviewError):
            self.review(quote=quote)
        quote = copy.deepcopy(self.quote)
        quote["components"].pop()
        with self.assertRaises(ReviewError):
            self.review(quote=quote)

    def test_baseline_policy_mismatches_are_not_silently_repaired(self):
        for section, key, value in (("token", "name", "Other"), ("token", "symbol", "OTHER"),
                                    ("pool", "fee", 3000), ("allocation", "swarmBps", 2000)):
            baseline = copy.deepcopy(self.baseline)
            baseline[section][key] = value
            with self.subTest(key=key), self.assertRaises(ReviewError):
                update_symbol(baseline)

    def test_cli_reports_missing_quote_and_cannot_broadcast(self):
        output = io.StringIO()
        with redirect_stdout(output):
            code = main([str(ROOT / "config/policy-baseline.json")])
        self.assertEqual(code, 2)
        self.assertFalse(json.loads(output.getvalue())["broadcastAuthorized"])

    def test_cli_failure_returns_no_confirmation_report(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "test") as temporary:
            candidate = update_symbol(self.baseline)
            candidate["token"]["symbol"] = "CONDITIONAL"
            path = Path(temporary) / "candidate.json"
            path.write_text(json.dumps(candidate))
            output, error = io.StringIO(), io.StringIO()
            with redirect_stdout(output), redirect_stderr(error):
                code = main([str(ROOT / "config/policy-baseline.json"), "--candidate", str(path)])
            self.assertEqual(code, 1)
            self.assertEqual(output.getvalue(), "")
            self.assertIn("STOP before payment or deployment", error.getvalue())

    def test_duplicate_keys_and_nonfinite_json_fail(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "test") as temporary:
            path = Path(temporary) / "bad.json"
            for raw in ('{"symbol":"CONDITIONALS","symbol":"CONDITIONAL"}', '{"value":NaN}', '{"value":Infinity}'):
                path.write_text(raw)
                with self.assertRaises(ReviewError):
                    load(path)


if __name__ == "__main__":
    unittest.main()
