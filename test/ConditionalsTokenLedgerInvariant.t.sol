// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ConditionalsToken} from "../src/ConditionalsToken.sol";

/// @dev Drives the token with several actors and keeps an independent ledger of every balance and
/// allowance. Calls that must fail are made too, and each is checked to revert with the expected
/// error and to leave the ledger untouched.
contract LedgerHandler is Test {
    ConditionalsToken public immutable token;
    uint256 public constant ACTORS = 5;
    address[ACTORS] public actors;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    uint256 public okCalls;
    uint256 public refusedCalls;

    constructor(ConditionalsToken token_) {
        token = token_;
        for (uint256 i; i < ACTORS; ++i) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("ledger actor", i)))));
        }
        // actors[0] receives the whole supply in setUp.
        ghostBalance[actors[0]] = token_.totalSupply();
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % ACTORS];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 0, ghostBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ++okCalls;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = infinite ? type(uint256).max : bound(amountSeed, 0, 2 * token.totalSupply());
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        ghostAllowance[owner][spender] = amount;
        ++okCalls;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 cap = ghostAllowance[owner][spender];
        if (ghostBalance[owner] < cap) cap = ghostBalance[owner];
        uint256 amount = bound(amountSeed, 0, cap);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        if (ghostAllowance[owner][spender] != type(uint256).max) ghostAllowance[owner][spender] -= amount;
        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        ++okCalls;
    }

    /// Spending more than the allowance (while the balance would cover it) must revert.
    function overspendAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 extraSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 allowance = ghostAllowance[owner][spender];
        if (allowance == type(uint256).max || allowance >= ghostBalance[owner]) return;
        uint256 amount = bound(extraSeed, allowance + 1, ghostBalance[owner]);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount)
        );
        token.transferFrom(owner, spender, amount);
        ++refusedCalls;
    }

    /// Moving more than the balance must revert, directly or through an unlimited allowance.
    function overspendBalance(uint256 fromSeed, uint256 toSeed, uint256 extraSeed, bool viaAllowance) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = ghostBalance[from];
        uint256 amount = bound(extraSeed, balance + 1, type(uint256).max);
        bytes memory err = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount);
        if (viaAllowance) {
            vm.prank(from);
            token.approve(to, type(uint256).max);
            ghostAllowance[from][to] = type(uint256).max;
            vm.prank(to);
            vm.expectRevert(err);
            token.transferFrom(from, to, amount);
        } else {
            vm.prank(from);
            vm.expectRevert(err);
            token.transfer(to, amount);
        }
        ++refusedCalls;
    }

    /// Sending to the zero address is not a burn: it must revert and the supply must stay fixed.
    function sendToZero(uint256 fromSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        uint256 amount = bound(amountSeed, 0, ghostBalance[from]);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        ++refusedCalls;
    }

    /// A spender cannot be the zero address.
    function approveZero(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), amountSeed);
        ++refusedCalls;
    }
}

contract ConditionalsTokenLedgerInvariantTest is StdInvariant, Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    ConditionalsToken private token;
    LedgerHandler private handler;

    function setUp() public {
        token = new ConditionalsToken();
        handler = new LedgerHandler(token);
        assertTrue(token.transfer(handler.actors(0), SUPPLY));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = LedgerHandler.transfer.selector;
        selectors[1] = LedgerHandler.approve.selector;
        selectors[2] = LedgerHandler.transferFrom.selector;
        selectors[3] = LedgerHandler.overspendAllowance.selector;
        selectors[4] = LedgerHandler.overspendBalance.selector;
        selectors[5] = LedgerHandler.sendToZero.selector;
        selectors[6] = LedgerHandler.approveZero.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_everyBalanceMatchesTheLedgerAndSupplyIsFixed() public view {
        uint256 sum;
        for (uint256 i; i < handler.ACTORS(); ++i) {
            address a = handler.actors(i);
            assertEq(token.balanceOf(a), handler.ghostBalance(a), "balance drifted from ledger");
            sum += token.balanceOf(a);
        }
        assertEq(sum, SUPPLY, "actors no longer hold the whole supply");
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(token.balanceOf(address(0)), 0, "tokens reached the zero address");
        assertEq(token.balanceOf(address(this)), 0, "deployer regained tokens");
        assertEq(token.balanceOf(address(handler)), 0, "handler gained tokens");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_everyAllowanceMatchesTheLedger() public view {
        for (uint256 i; i < handler.ACTORS(); ++i) {
            for (uint256 j; j < handler.ACTORS(); ++j) {
                address o = handler.actors(i);
                address s = handler.actors(j);
                assertEq(token.allowance(o, s), handler.ghostAllowance(o, s), "allowance drifted from ledger");
            }
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_metadataIsExactlyTheRequestedSymbol() public view {
        assertEq(token.name(), "Conditionals");
        assertEq(token.symbol(), "CONDITIONALS");
        assertEq(token.decimals(), 18);
    }

    /// The raw ABI return of symbol() carries all 12 bytes: offset 0x20, length 12, then the bytes
    /// "CONDITIONALS" left-aligned with zero padding. A form or indexer reading it gets no truncation.
    function test_symbolRawAbiEncodingCarriesAllTwelveBytes() public view {
        (bool ok, bytes memory raw) = address(token).staticcall(abi.encodeWithSignature("symbol()"));
        assertTrue(ok);
        assertEq(raw.length, 96);
        (uint256 offset, uint256 length, bytes32 word) = abi.decode(raw, (uint256, uint256, bytes32));
        assertEq(offset, 0x20);
        assertEq(length, 12);
        assertEq(word, bytes32("CONDITIONALS"));
        assertTrue(word != bytes32("CONDITIONAL"));
        // Every byte is uppercase ASCII A-Z: no hidden whitespace, homoglyph or terminator.
        bytes memory s = bytes(token.symbol());
        for (uint256 i; i < s.length; ++i) {
            assertTrue(s[i] >= 0x41 && s[i] <= 0x5A, "symbol has a non A-Z byte");
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_unlimitedAllowanceIsNeverConsumed(uint256 amountSeed, uint256 rounds) public {
        address owner = handler.actors(0);
        address spender = handler.actors(1);
        rounds = bound(rounds, 1, 5);
        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        uint256 moved;
        for (uint256 i; i < rounds; ++i) {
            uint256 amount = bound(uint256(keccak256(abi.encode(amountSeed, i))), 0, SUPPLY / 10);
            vm.prank(spender);
            assertTrue(token.transferFrom(owner, spender, amount));
            moved += amount;
        }
        assertEq(token.allowance(owner, spender), type(uint256).max);
        assertEq(token.balanceOf(spender), moved);
        assertEq(token.balanceOf(owner), SUPPLY - moved);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_reApprovalReplacesRatherThanAdds(uint256 first, uint256 second) public {
        address owner = handler.actors(0);
        address spender = handler.actors(2);
        first = bound(first, 1, SUPPLY);
        second = bound(second, 0, first - 1);
        vm.startPrank(owner);
        token.approve(spender, first);
        token.approve(spender, second);
        vm.stopPrank();
        assertEq(token.allowance(owner, spender), second);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, second, second + 1)
        );
        token.transferFrom(owner, spender, second + 1);
    }
}
