#!/usr/bin/env python3
"""Read-only symbol change and confirmation report. No network, signing, or payment APIs."""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import sys
import time


NAME = "Conditionals"
SYMBOL = "CONDITIONALS"
OLD_SYMBOL = "CONDITIONAL"
CHAIN_ID = 4663
SUPPLY = "1000000000000000000000000000"
PAIR = "0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127"
OWNER = "0x612a9bb008e16ef2d24f41dae9fc661831d93367"


class ReviewError(ValueError):
    """The proposed launch cannot proceed to confirmation."""


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def require(condition, message):
    if not condition:
        raise ReviewError(message)


def validate_policy(config):
    require(isinstance(config, dict), "Configuration must be a JSON object")
    token = config.get("token", {})
    pool = config.get("pool", {})
    require(isinstance(token, dict) and isinstance(pool, dict), "Missing token or pool configuration")
    require(type(config.get("chainId")) is int and config["chainId"] == CHAIN_ID, "Expected chain ID 4663")
    require(token.get("name") == NAME, "Token name must remain exactly Conditionals")
    require(type(token.get("decimals")) is int and token["decimals"] == 18, "Token decimals must remain 18")
    require(token.get("totalSupply") == SUPPLY, "Supply must remain one billion tokens, as a minor-unit string")
    require(token.get("symbol") in (OLD_SYMBOL, SYMBOL), "Unexpected baseline symbol; refuse an unrelated token")
    require(str(pool.get("pairedCurrency")).lower() == PAIR, "Paired currency must remain the supplied IMD address")
    require(type(pool.get("fee")) is int and pool["fee"] == 12500, "Pool fee must remain 12500")
    require(type(pool.get("tickSpacing")) is int and pool["tickSpacing"] == 60, "Tick spacing must remain 60")
    require(pool.get("initialPrice") == "79228162514264337593543950336", "Preserve the policy initialPrice field")
    require(str(config.get("owner")).lower() == OWNER, "Preserve the supplied launch owner")
    require(isinstance(config.get("hook"), dict) and bool(config["hook"]), "Missing hook configuration")
    require(isinstance(config.get("allocation"), dict), "Missing allocation configuration")
    allocation = config["allocation"]
    for key, expected in (("swarmBps", 1000), ("poolBps", 8000), ("remainderBps", 1000)):
        require(type(allocation.get(key)) is int and allocation[key] == expected, f"Preserve allocation.{key}")


def update_symbol(baseline):
    """Preserve unknown/nested fields and their types; do not rebuild configuration from defaults."""
    validate_policy(baseline)
    updated = copy.deepcopy(baseline)
    updated["token"]["symbol"] = SYMBOL
    return updated


def assert_symbol_only(baseline, candidate):
    expected = update_symbol(baseline)
    require(isinstance(candidate, dict), "Candidate must be a JSON object")
    require(candidate.get("token", {}).get("symbol") == SYMBOL, "Refuse shortened, substituted, or normalized symbol")
    require(canonical(candidate) == canonical(expected), "Refuse changes outside token.symbol, including omitted fields")


def validate_capabilities(capabilities, config_hash):
    require(isinstance(capabilities, dict), "System validation must be an object")
    require(capabilities.get("configurationSha256") == config_hash, "System validation belongs to another configuration")
    require(capabilities.get("chainId") == CHAIN_ID, "System validation is for another chain")
    require(capabilities.get("exactSymbolSupported") is True, "Launch system has not confirmed exact-symbol support")
    require(capabilities.get("acceptedSymbol") == SYMBOL, "Launch system would truncate or substitute CONDITIONALS; stop")
    length = capabilities.get("maxSymbolLength")
    require(type(length) is int and length >= len(SYMBOL), "Launch system cannot support all 12 characters; stop")


def format_units(amount, decimals):
    if decimals == 0:
        return str(amount)
    whole, fraction = divmod(amount, 10 ** decimals)
    tail = str(fraction).zfill(decimals).rstrip("0")
    return f"{whole}.{tail}" if tail else str(whole)


def total_cost(quote, config_hash, now):
    """Sum exact integers per currency; never add amounts denominated in different assets."""
    require(isinstance(quote, dict), "Quote must be an object")
    require(quote.get("configurationSha256") == config_hash, "Quote belongs to another configuration")
    require(quote.get("chainId") == CHAIN_ID, "Quote is for another chain")
    require(isinstance(quote.get("quoteId"), str) and bool(quote["quoteId"].strip()), "Missing quote identifier")
    require(quote.get("complete") is True, "Quote must include all costs, including gas and any required funding")
    issued = quote.get("issuedAt")
    expires = quote.get("expiresAt")
    require(type(issued) is int and type(expires) is int, "Quote timestamps must be integer Unix seconds")
    require(0 <= issued <= now < expires, "Quote is expired, not yet valid, or has an invalid interval")
    components = quote.get("components")
    require(isinstance(components, list) and bool(components), "Quote has no cost components")
    totals = {}
    kinds = set()
    for component in components:
        require(isinstance(component, dict), "Cost component must be an object")
        currency = component.get("currency")
        amount = component.get("amount")
        decimals = component.get("decimals")
        kind = component.get("kind")
        require(isinstance(currency, str) and re.fullmatch(r"[A-Z0-9]{1,16}", currency), "Invalid cost currency")
        require(isinstance(amount, str) and re.fullmatch(r"0|[1-9][0-9]*", amount), "Cost amount must be an unsigned integer string")
        require(type(decimals) is int and 0 <= decimals <= 36, "Invalid cost decimals")
        require(kind in ("service", "gas", "funding", "other"), "Invalid cost component kind")
        require(isinstance(component.get("label"), str) and bool(component["label"].strip()), "Missing cost label")
        kinds.add(kind)
        if currency not in totals:
            totals[currency] = {"amount": 0, "decimals": decimals}
        require(totals[currency]["decimals"] == decimals, "Inconsistent decimals for the same cost currency")
        totals[currency]["amount"] += int(amount)
    require({"service", "gas", "funding"} <= kinds, "Quote must explicitly include service, gas, and funding (even if zero)")
    return [
        {
            "currency": currency,
            "decimals": values["decimals"],
            "amount": str(values["amount"]),
            "display": f"{format_units(values['amount'], values['decimals'])} {currency}",
        }
        for currency, values in sorted(totals.items())
    ]


def prepare_review(baseline, *, candidate=None, capabilities=None, quote=None, now=None):
    updated = update_symbol(baseline) if candidate is None else copy.deepcopy(candidate)
    assert_symbol_only(baseline, updated)
    config_hash = digest(updated)
    missing = []
    if capabilities is None:
        missing.append("launch system validation of exact 12-character symbol")
    else:
        validate_capabilities(capabilities, config_hash)
    cost = None
    if quote is None:
        missing.append("complete, current deployment quote")
    else:
        cost = total_cost(quote, config_hash, int(time.time()) if now is None else now)
    return {
        "status": "awaiting-system-validation-and-quote" if missing else "awaiting-user-confirmation",
        "configuration": updated,
        "configurationSha256": config_hash,
        "baselineSha256": digest(baseline),
        "changes": [] if baseline["token"]["symbol"] == SYMBOL else [
            {"path": "token.symbol", "before": baseline["token"]["symbol"], "after": SYMBOL}
        ],
        "symbolLength": len(SYMBOL),
        "totalCost": cost,
        "quote": copy.deepcopy(quote),
        "systemValidation": copy.deepcopy(capabilities),
        "missing": missing,
        "confirmationRequired": True,
        "broadcastAuthorized": False,
        "deployment": {"status": "not-broadcast"},
    }


def no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_nonfinite(value):
    raise ReviewError(f"Non-JSON numeric constant: {value}")


def load(path):
    with Path(path).open(encoding="utf-8") as source:
        return json.load(source, object_pairs_hook=no_duplicate_keys, parse_constant=reject_nonfinite)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", help="Original launch configuration; it will not be modified")
    parser.add_argument("--candidate", help="Optional round-trip configuration from the launch form to verify")
    parser.add_argument("--capabilities", help="Exact-symbol validation supplied by the launch system")
    parser.add_argument("--quote", help="Complete quote supplied by the launch system")
    args = parser.parse_args(argv)
    try:
        report = prepare_review(
            load(args.baseline),
            candidate=load(args.candidate) if args.candidate else None,
            capabilities=load(args.capabilities) if args.capabilities else None,
            quote=load(args.quote) if args.quote else None,
        )
    except (OSError, ValueError, TypeError, AttributeError) as error:
        print(f"STOP before payment or deployment: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False))
    # An incomplete report is still useful to review, but must stop a calling deployment pipeline.
    return 2 if report["missing"] else 0


if __name__ == "__main__":
    sys.exit(main())
