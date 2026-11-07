// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ConditionalsToken} from "../src/ConditionalsToken.sol";

contract TokenHolder {
    function pay(ConditionalsToken token, address to, uint256 amount) external {
        require(token.transfer(to, amount));
    }
}

/// @dev Reconstructed policy baseline for differential tests, not a historical deployed contract.
contract PolicyBaselineToken is ERC20 {
    constructor() ERC20("Conditionals", "CONDITIONAL") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

contract ConditionalsTokenTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    ConditionalsToken private token;
    address private alice;
    address private bob;

    function setUp() public {
        token = new ConditionalsToken();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    function test_exactMetadataAndFactorySupply() public view {
        assertEq(token.name(), "Conditionals");
        assertEq(token.symbol(), "CONDITIONALS");
        assertEq(bytes(token.symbol()).length, 12);
        assertNotEq(token.symbol(), "CONDITIONAL");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_factoryAllocationAndFeeReturnMoveExactAmounts() public {
        TokenHolder distributor = new TokenHolder();
        TokenHolder pool = new TokenHolder();
        assertTrue(token.transfer(address(distributor), SUPPLY / 10));
        assertTrue(token.transfer(address(pool), SUPPLY * 8 / 10));
        assertTrue(token.transfer(alice, SUPPLY / 10));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(distributor)), 100_000_000 ether);
        assertEq(token.balanceOf(address(pool)), 800_000_000 ether);
        assertEq(token.balanceOf(alice), 100_000_000 ether);
        distributor.pay(token, address(pool), 10 ether);
        pool.pay(token, address(this), 7 ether);
        distributor.pay(token, bob, 3 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 2 ether));
        assertEq(token.balanceOf(bob), 5 ether);
        assertEq(token.balanceOf(address(this)), 7 ether);
        assertEq(token.balanceOf(address(pool)), 800_000_003 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approvedTransferAndAllowanceConsumption() public {
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 4 ether);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 3 ether));
        assertEq(token.balanceOf(alice), 7 ether);
        assertEq(token.balanceOf(bob), 3 ether);
        assertEq(token.allowance(alice, bob), 1 ether);
    }

    function test_unauthorizedSpendFailsWithoutMovingBalances() public {
        token.transfer(alice, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_invalidReceiverAndInsufficientBalanceFail() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_zeroAndSelfTransfersPreserveSupply() public {
        token.transfer(alice, 5 ether);
        vm.startPrank(alice);
        assertTrue(token.transfer(bob, 0));
        assertTrue(token.transfer(alice, 5 ether));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 5 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_noMintAdminOrMetadataChangeEvenForFactory() public {
        bytes[7] memory attempts = [
            abi.encodeWithSignature("mint(address,uint256)", alice, 1),
            abi.encodeWithSignature("setSymbol(string)", "CONDITIONAL"),
            abi.encodeWithSignature("setName(string)", "Other"),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("transferOwnership(address)", alice),
            abi.encodeWithSignature("upgradeTo(address)", alice),
            abi.encodeWithSignature("initialize(address)", alice)
        ];
        for (uint256 i; i < attempts.length; ++i) {
            (bool factoryOK,) = address(token).call(attempts[i]);
            assertFalse(factoryOK);
            vm.prank(alice);
            (bool outsiderOK,) = address(token).call(attempts[i]);
            assertFalse(outsiderOK);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.symbol(), "CONDITIONALS");
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_symbolOnlyDifferenceFromPolicyToken(uint256 rawAmount, uint256 rawSpend) public {
        PolicyBaselineToken baseline = new PolicyBaselineToken();
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        uint256 spend = bound(rawSpend, 0, amount);
        token.transfer(alice, amount);
        baseline.transfer(alice, amount);
        vm.startPrank(alice);
        token.approve(bob, spend);
        baseline.approve(bob, spend);
        vm.stopPrank();
        vm.startPrank(bob);
        token.transferFrom(alice, bob, spend);
        baseline.transferFrom(alice, bob, spend);
        vm.stopPrank();
        assertEq(token.balanceOf(address(this)), baseline.balanceOf(address(this)));
        assertEq(token.balanceOf(alice), baseline.balanceOf(alice));
        assertEq(token.balanceOf(bob), baseline.balanceOf(bob));
        assertEq(token.allowance(alice, bob), baseline.allowance(alice, bob));
        assertEq(token.totalSupply(), baseline.totalSupply());
        assertEq(token.name(), baseline.name());
        assertEq(token.decimals(), baseline.decimals());
        assertNotEq(token.symbol(), baseline.symbol());
    }

    function testFuzz_insufficientBalanceNeverChangesSupply(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, amount));
        token.transfer(bob, amount);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }
}
