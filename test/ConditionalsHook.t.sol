// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {ConditionalsToken} from "../src/ConditionalsToken.sol";
import {ConditionalsHook} from "../src/ConditionalsHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolActor} from "./mocks/PoolActor.sol";

contract ConditionalsHookTest is Test {
    using StateLibrary for IPoolManager;

    uint160 private constant Q96 = 79228162514264337593543950336;
    int256 private constant LIQUIDITY = 1e24;
    int24 private constant LOWER = -887220;
    int24 private constant UPPER = 887220;
    IPoolManager private manager;
    ConditionalsHook private hook;
    ConditionalsToken private token;
    MockERC20 private pair;
    PoolActor private factory;
    PoolKey private key;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new ConditionalsToken();
        pair = new MockERC20("Test IMD", "IMD", 1_000_000_000 ether);
        bytes memory code = abi.encodePacked(type(ConditionalsHook).creationCode, abi.encode(manager));
        (address predicted, bytes32 salt) = _mine(code, 0);
        hook = new ConditionalsHook{salt: salt}(manager);
        assertEq(address(hook), predicted);
        (address a, address b) =
            address(token) < address(pair) ? (address(token), address(pair)) : (address(pair), address(token));
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 12500, 60, IHooks(address(hook)));
        factory = new PoolActor(manager);
        token.transfer(address(factory), token.totalSupply() * 8 / 10);
        pair.transfer(address(factory), pair.totalSupply() * 8 / 10);
    }

    function test_permissionsAndMinedAddressMatchExactly() public view {
        Hooks.Permissions memory expected;
        expected.beforeInitialize = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.BEFORE_INITIALIZE);
        assertEq(address(hook.poolManager()), address(manager));
        assertLt(address(hook).code.length, 24576);
    }

    function test_initializationFromFactoryPreservesPoolTerms() public {
        vm.prank(address(factory));
        assertEq(manager.initialize(key, Q96), 0);
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(price, Q96);
        assertEq(tick, 0);
        assertEq(protocolFee, 0);
        assertEq(lpFee, 12500);
        assertEq(key.tickSpacing, 60);
    }

    function testFuzz_acceptsFactoryDerivedOpeningPrice(uint160 rawPrice) public {
        uint160 price = uint160(bound(rawPrice, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        vm.prank(address(factory));
        manager.initialize(key, price);
        (uint160 actual,,,) = manager.getSlot0(key.toId());
        assertEq(actual, price);
    }

    function test_onlyManagerCanCallInitializationEvenWithForgedSender() public {
        vm.expectRevert(ConditionalsHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(manager), key, Q96);
        vm.prank(address(factory));
        vm.expectRevert(ConditionalsHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(factory), key, Q96);
        vm.prank(address(manager));
        assertEq(hook.beforeInitialize(address(factory), key, Q96), IHooks.beforeInitialize.selector);
    }

    function test_rejectsNullManager() public {
        vm.expectRevert(ConditionalsHook.InvalidPoolManager.selector);
        new ConditionalsHook(IPoolManager(address(0)));
    }

    function test_rejectsDeploymentAtWrongPermissionBits() public {
        bytes memory code = abi.encodePacked(type(ConditionalsHook).creationCode, abi.encode(manager));
        bytes32 hash = keccak256(code);
        bytes32 salt;
        address predicted;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            predicted = _predict(salt, hash);
            if (!HookFlags.matches(predicted, HookFlags.BEFORE_INITIALIZE)) break;
        }
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new ConditionalsHook{salt: salt}(manager);
    }

    function test_predictedPoolCannotInitializeBeforeHookHasCode() public {
        bytes memory code = abi.encodePacked(type(ConditionalsHook).creationCode, abi.encode(manager));
        (address vacant,) = _mine(code, 200_000);
        assertEq(vacant.code.length, 0);
        PoolKey memory unopened = key;
        unopened.hooks = IHooks(vacant);
        vm.expectRevert();
        manager.initialize(unopened, Q96);
    }

    function test_duplicatePoolInitializationFails() public {
        manager.initialize(key, Q96);
        vm.expectRevert();
        manager.initialize(key, Q96);
    }

    function test_disabledCallbacksAndAdminSelectorsAreUnavailable() public {
        bytes[4] memory attempts = [
            abi.encodeCall(IHooks.beforeSwap, (address(factory), key, SwapParams(true, -1, Q96 / 2), bytes(""))),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("setFee(uint256)", 100),
            abi.encodeWithSignature("transferOwnership(address)", address(this))
        ];
        for (uint256 i; i < attempts.length; ++i) {
            (bool ok,) = address(hook).call(attempts[i]);
            assertFalse(ok);
        }
        (bool owned,) = address(hook).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(owned);
    }

    function testFuzz_buysAndSellsHaveNoExtraFeeOrDelta(bool zeroForOne, bool exactInput, uint96 rawAmount) public {
        _seed(key);
        PoolKey memory baseline = key;
        baseline.hooks = IHooks(address(0));
        _seed(baseline);
        int256 amount = int256(bound(rawAmount, 1e6, 1e20));
        SwapParams memory params = SwapParams(zeroForOne, exactInput ? -amount : amount, _limit(zeroForOne));
        BalanceDelta withHook = factory.swap(key, params);
        BalanceDelta withoutHook = factory.swap(baseline, params);
        assertEq(BalanceDelta.unwrap(withHook), BalanceDelta.unwrap(withoutHook));
        int128 input = zeroForOne ? withHook.amount0() : withHook.amount1();
        int128 output = zeroForOne ? withHook.amount1() : withHook.amount0();
        assertLt(input, 0);
        assertGt(output, 0);
        if (exactInput) assertEq(-int256(input), amount);
        else assertEq(int256(output), amount);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(pair.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_factoryCanCollectFeesWithZeroLiquidityChangeAndUnwind() public {
        _seed(key);
        factory.swap(key, SwapParams(true, -1 ether, _limit(true)));
        factory.swap(key, SwapParams(false, -1 ether, _limit(false)));
        BalanceDelta collected = factory.modify(key, ModifyLiquidityParams(LOWER, UPPER, 0, bytes32(0)));
        assertGt(collected.amount0(), 0);
        assertGt(collected.amount1(), 0);
        BalanceDelta again = factory.modify(key, ModifyLiquidityParams(LOWER, UPPER, 0, bytes32(0)));
        assertEq(BalanceDelta.unwrap(again), 0);
        BalanceDelta removed = factory.modify(key, ModifyLiquidityParams(LOWER, UPPER, -LIQUIDITY, bytes32(0)));
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        assertEq(manager.getLiquidity(key.toId()), 0);
    }

    function test_donationsAccrueToLPWithoutHookCustody() public {
        _seed(key);
        factory.donate(key, 1 ether, 2 ether);
        BalanceDelta collected = factory.modify(key, ModifyLiquidityParams(LOWER, UPPER, 0, bytes32(0)));
        assertApproxEqAbs(uint128(collected.amount0()), 1 ether, 1);
        assertApproxEqAbs(uint128(collected.amount1()), 2 ether, 1);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(pair.balanceOf(address(hook)), 0);
    }

    function _seed(PoolKey memory pool) private {
        vm.prank(address(factory));
        manager.initialize(pool, Q96);
        factory.modify(pool, ModifyLiquidityParams(LOWER, UPPER, LIQUIDITY, bytes32(0)));
    }

    function _limit(bool zeroForOne) private pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _predict(bytes32 salt, bytes32 hash) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
    }

    function _mine(bytes memory code, uint256 start) private view returns (address predicted, bytes32 salt) {
        bytes32 hash = keccak256(code);
        for (uint256 i = start; i < start + 200_000; ++i) {
            salt = bytes32(i);
            predicted = _predict(salt, hash);
            if (HookFlags.matches(predicted, HookFlags.BEFORE_INITIALIZE)) return (predicted, salt);
        }
        revert("no matching CREATE2 salt");
    }
}
