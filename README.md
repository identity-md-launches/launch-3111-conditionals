# Conditionals

This Foundry project builds `ConditionalsToken` with name **Conditionals**, symbol
**CONDITIONALS** (exactly 12 ASCII characters), 18 decimals, and a fixed supply of
**1,000,000,000 tokens**. The full supply is minted once to the deploying launch
factory. No payment or transaction is sent by this project.

The explicit 12-character instruction takes precedence over the older
`Token symbol: CONDITIONAL` field. Neither the contract nor the review tool
shortens, pads, normalizes, or substitutes the requested symbol.

## Baseline and decisions

The supplied checkout contained pinned checks and launch-policy references, but
no prior Conditionals source or saved launch form. Following the retry's direction
to decide and finish, this implementation uses the supplied policy as its baseline:
a standard fixed-supply ERC-20 and a minimal v4 initialization hook. It adds no
custom swap fee, administrative powers, transfer restrictions, shares, or custom
accounting. This is a documented reconstruction, **not evidence of equivalence to
an unavailable historical hook**.

`config/policy-baseline.json` records that reconstruction with the old symbol so
the change is reviewable. It is an input to the review tool, **not a deployment
manifest**. Its recipient descriptions identify the factory's existing allocation
roles; they are not substitute on-chain addresses.

`tools/prepare_launch.py` copies a supplied baseline and changes only
`token.symbol`. It preserves every other field, including unknown nested fields,
fee settings, recipient addresses and permissions. Its optional `--candidate`
argument rejects form round trips that alter anything else. If the launch system
has an existing configuration beyond this policy reconstruction, apply the
symbol change to that configuration and retain its existing hook implementation;
this task does not authorize replacing different existing behavior with the
minimal hook here. The launch operator must reconcile that baseline before
requesting confirmation.

| Open point | Decision and reason |
| --- | --- |
| Two different symbols in the brief | Use `CONDITIONALS`; the explicit exact-symbol instruction is controlling. |
| Missing historical source | Implement the supplied policy's minimal hook and identify the reconstruction; preserve any supplied baseline with a field-level guard. |
| Unspecified optional hook behavior | Enable only mandatory `beforeInitialize`; no discretionary tax, permissions, or admin functions. |
| Token decimals | Use 18, consistent with the supplied standard launch policy and IMD pair; test the exact minor-unit supply. |
| Deployment cost and form limits | Do not invent them. Import current system validation and a complete quote; missing data prevents readiness for confirmation. |
| Addresses determined during launch | Let the existing factory/deployer resolve them. No zero/burn-address defaults or operator keys are used. |

## Final configuration for review

The generated, complete configuration report is
[`review/conditionals-review.json`](review/conditionals-review.json).

| Parameter | Value |
| --- | --- |
| Chain | Robinhood Chain, chain ID `4663` (assignment policy) |
| Name / symbol | `Conditionals` / `CONDITIONALS` |
| Decimals | `18` |
| Total supply in minor units | `1000000000000000000000000000` |
| Initial supply recipient | Factory deploying the token (`msg.sender` in token constructor) |
| Swarm allocation | 10%: 100,000,000 tokens to the factory-created MerkleDistributor |
| Pool allocation | 80%: 800,000,000 tokens, seeded by the factory |
| Remaining allocation | 10%: 100,000,000 tokens to the paying wallet, or chain treasury when nobody pays |
| Paired currency | IMD, `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`, 18 decimals per assignment |
| Pool fee | `12500` = 1.25% LP fee, unchanged; not a deployment cost |
| Tick spacing | `60` |
| Policy `initialPrice` | `79228162514264337593543950336` |
| Actual opening price | Derived by the factory/deployer from the 2,500 IMD opening market cap and currency ordering; not forced to the policy's 1:1 field |
| Launch owner | `0x612a9bb008e16ef2d24f41dae9fc661831d93367` |
| Hook | `ConditionalsHook`, initialization acknowledgement only |
| Hook fee / token transfer tax | None in the reconstructed minimal policy baseline |
| Hook permissions | `beforeInitialize` only; mask `8192` / `0x2000` |
| Contract admin powers | None; neither factory nor launch wallet acquires an admin role |
| Total deployment cost | **Unavailable: a current complete system quote has not been supplied.** This is not a zero-cost quote. |
| Launch status | Not paid or broadcast; exact-symbol system validation, quote and explicit user confirmation remain required |

Factory-held LP fees and their policy distribution remain the existing launch
system's responsibility. These contracts do not redirect fees or allocate tokens
to themselves. The supplied reference describes the factory's LP fee split as
80% payer / 20% network; that split is not implemented or altered in the hook.

## Contracts and deployment parameters

| Contract | Constructor arguments | Responsibility |
| --- | --- | --- |
| `ConditionalsToken` | None | Mint the entire fixed supply to the factory; standard exact ERC-20 transfers and approvals |
| `ConditionalsHook` | `IPoolManager poolManager_` = `$poolManager` | Accept initialization only from that manager and return `IHooks.beforeInitialize.selector` |

Both names fit the launch's 32-character Solidity-name limit. Neither contract
has text/array constructor parameters, upgrade functions, later minting, external
library links, or constructor calls to other contracts. The hook's constructor
rejects a zero manager and verifies its own address permission bits, without
requiring the manager to have code during empty-chain construction checks.

The hook implements the minimal callback directly against the v4 interfaces.
`getHookPermissions()` is pure and only enables `beforeInitialize`; all other
flags are false. Disabled selectors are absent and revert if called directly.
There is no hook ownership because there are no admin operations to perform.
The listed launch owner remains the owner in the configuration; the factory is
only the initial token holder and liquidity custodian under the existing policy.

The deployment service must mine a CREATE2 salt using its actual factory address,
the hook creation code, and the encoded `$poolManager`. The resulting address must
satisfy `uint160(hook) & 0x3fff == 0x2000`. The tests deploy the real hook this way.
The factory must deploy it and initialize the pool atomically: the required
callback prevents initialization before code exists at its predicted address.
Once code exists this stateless hook adds no sender allowlist, pool restrictions,
pause, or price gate. It accepts the factory's derived opening price. It has no
liquidity-removal callback, so it cannot block zero-liquidity fee collection.

Changing token metadata changes creation code and can change CREATE2 predictions,
token ordering, the hook address and pool ID. The deployment service must recompute
derived values after this symbol correction using the existing launch algorithm;
preserving configuration does not mean retaining stale predicted addresses.

## Review and confirmation flow

Python 3 standard library only; the command has no networking, payment, wallet,
signing, or broadcasting code:

```sh
python3 tools/prepare_launch.py config/policy-baseline.json
```

Without a quote and system validation this prints the final configuration with
`totalCost: null`, lists the missing checks, and exits **2**. The checked-in review
report is this output. An invalid symbol or unrelated change exits **1** and emits
no confirmation report. There is no shortened-symbol fallback.

When the launch system has validated the exact symbol and produced a current
quote, the operator can prepare the confirmation report:

```sh
python3 tools/prepare_launch.py config/policy-baseline.json \
  --capabilities path/to/system-validation.json \
  --quote path/to/current-quote.json
```

Use the actual existing baseline path when one is available. To check the launch
form's returned configuration, also pass `--candidate path/to/form-result.json`.
Every field besides the symbol must be identical, including types and missing
fields. Input JSON with duplicate keys or non-finite values is refused.

The system-validation file must contain:

| Field | Required value |
| --- | --- |
| `chainId` | `4663` |
| `configurationSha256` | Digest from the final report |
| `exactSymbolSupported` | `true`, based on the actual deployment system |
| `acceptedSymbol` | Exactly `CONDITIONALS` |
| `maxSymbolLength` | Integer at least `12` |

The quote must contain `chainId`, `configurationSha256`, a nonempty `quoteId`,
integer Unix-second `issuedAt` and `expiresAt`, `complete: true`, and a nonempty
`components` array. Each component has `kind` (`service`, `gas`, `funding`, or
`other`), a descriptive `label`, uppercase `currency`, integer `decimals`, and an
unsigned minor-unit integer **string** `amount`. Service, gas (including applicable
L1 data costs) and required funding must all appear, explicitly zero only when
the quote actually says zero. Expired, future-dated, incomplete, or mismatched
quotes are rejected. Amounts are summed with exact integers, grouped by currency;
ETH and IMD are never added into a misleading single numeric total.

Digests use SHA-256 over UTF-8 JSON serialized with sorted keys, no optional
whitespace, non-ASCII characters unescaped and non-finite values disallowed.
They bind documents to configurations, **not authenticate the system or prices**.
The operator must obtain the validation and quote through the trusted launch
service, including an honest list of every cost. This repository cannot establish
the limits or prices of a service to which it has not been connected.

A successful report exits **0**, sets `status: awaiting-user-confirmation`, and
still sets `confirmationRequired: true` and `broadcastAuthorized: false`. Exit 0
means ready to present, never permission to pay or deploy. Show the complete final
configuration, cost breakdown, total per currency, quote expiry and configuration
digest. The existing launch system must record the user's explicit confirmation
of those exact values before payment/broadcast. If limits, prices or configuration
change, obtain a fresh report and confirmation. If the system cannot retain all
12 characters, stop before payment/deployment and explain its limit.

## Build and tests

All Solidity dependencies are vendored as ordinary source files in `lib/`, with
upstream revisions and archive hashes in `dependencies.json`. Only the required
source subsets and licenses are included; there are no submodules or package
downloads during builds. Foundry pins solc **0.8.26**, Cancun, optimizer 200 runs,
and `bytecode_hash = "none"`. FFI and filesystem cheatcode permissions are not
enabled. The verification environment supplies the pinned compiler.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xd2d4dd436989ccd9321045e0dcc4eb7714e4f19539278712b00335d3f14bf3be forge test
forge fmt --check
python3 -m unittest discover -s test -p 'test_*.py' -v
```

Tests use no environment reads or writes, RPC, funded wallet, or external service.
They run on isolated real PoolManagers with locally minted test tokens.

- Exact metadata, supply and constructor allocation; normal, zero and self transfers.
- Wallet-to-wallet and contract-to-contract transfers, 10/80/10 factory payouts,
  distributor payments, and fee returns to the factory.
- Approval consumption, unauthorized spending, zero receiver, insufficient balance,
  absent admin/mint/metadata/upgrade selectors.
- Differential token behavior against a test-only reconstructed old-symbol token.
- Actual CREATE2 deployment, exact permission bits, wrong-address and null-manager
  rejection, callback authentication, initialization and premature/duplicate failures.
- Buy/sell and exact-input/output swaps compared with an otherwise identical
  unhooked pool: identical deltas, no extra fee or hook custody, no native funding.
- Factory fee collection through zero liquidity changes, donations and withdrawal.
- Stateful token conservation and immutable metadata across randomized transfers
  and approved spends.
- Review-tool success/failure paths, nested preservation, exact symbol support,
  stale/incomplete quotes, precise totals and confirmation state.

The pinned floor inputs were read as specifications. The delivered suites exercise
their relevant properties without their environment-dependent harness. They do
not claim to be a run of the independent verifier or a live-chain fork rehearsal.

## After launch

There are **no owner setters, deferred contract settings, keeper jobs, or pending
fee-conversion operations**. Nothing must be configured after deployment to allow
trades, transfers, or factory fee collection. The external service supplies the
manager at construction and resolves the factory-created recipients; nobody needs
to install placeholder addresses later.

The network's deployment operator remains responsible for checking chain ID 4663,
the actual manager code/interface, pair code and decimals, Cancun support, factory
policy, exact symbol support and total quoted cost before confirmation. It also
owns the separate manifest/attestation step and fork rehearsal. No `launch.json`
is supplied here because that step owns it.

After explicit confirmation and successful deployment, the operator must verify
the receipt and on-chain metadata, and return the **token address**, **hook
address**, **pool ID**, and **explorer transaction links**. Obtain the pool ID from
the manager's `Initialize` event and cross-check against the ordered PoolKey hash
(`keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hook))`). Verify token
supply and the 10/80/10 transfers and confirm the final mined permission mask.
Use the chain's verified explorer configuration and actual receipt hashes; no
addresses, pool IDs, or transaction links are fabricated in this delivery.

The contracts are immutable; changing metadata after a real deployment is not
supported. Do not send tokens or ETH directly to the hook: it has no custody or
rescue function. Normal swaps never pay it. Independent adversarial review and a
live-chain rehearsal remain release responsibilities; local tests are not an
audit. Slither, Mythril, and live-chain deployment were not run here.

## Sources

The assignment supplies the launch chain, pair, owner and economic policy. Those
values are inputs, not claimed as fresh on-chain observations. The pinned v4
source is the implementation authority for address bits and callback signatures.
See also the [Uniswap hook documentation](https://docs.uniswap.org/contracts/v4/concepts/hooks)
and [ERC-20 metadata interface](https://eips.ethereum.org/EIPS/eip-20), whose
`symbol()` returns a string without imposing an 11-character limit. A particular
launch form can still impose its own limit, which the confirmation flow must check.
