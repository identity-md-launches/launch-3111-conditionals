// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {ConditionalsToken} from "../src/ConditionalsToken.sol";
import {ConditionalsHook} from "../src/ConditionalsHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";

/// @dev Stand-in for the launch factory. `launch` does what the real factory does in ONE transaction:
/// deploy the token (whole supply to itself), CREATE2 the hook, initialize the pool, seed it with
/// tokens only and pay out the 10% swarm / 10% remainder tranches.
contract OneCallLaunchFactory is IUnlockCallback {
    IPoolManager public immutable manager;
    address private immutable controller;

    ConditionalsToken public token;
    ConditionalsHook public hook;
    PoolKey public key;
    int24 public lower;
    int24 public upper;
    uint128 public seeded;

    constructor(IPoolManager manager_) {
        manager = manager_;
        controller = msg.sender;
    }

    function launch(
        bytes32 hookSalt,
        address pair,
        uint24 fee,
        int24 spacing,
        uint128 liquidity,
        address distributor,
        address payer
    ) external returns (PoolId id) {
        require(msg.sender == controller, "controller only");
        token = new ConditionalsToken();
        require(token.balanceOf(address(this)) == token.INITIAL_SUPPLY(), "SupplyMismatch");
        hook = new ConditionalsHook{salt: hookSalt}(manager);
        bool tokenIs0 = address(token) < pair;
        key = PoolKey(
            Currency.wrap(tokenIs0 ? address(token) : pair),
            Currency.wrap(tokenIs0 ? pair : address(token)),
            fee,
            spacing,
            IHooks(address(hook))
        );
        // Opening price at tick 0; the token-only range sits entirely on the token's side of it.
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        (lower, upper) =
            tokenIs0 ? (spacing, TickMath.maxUsableTick(spacing)) : (TickMath.minUsableTick(spacing), -spacing);
        _modify(int256(uint256(liquidity)));
        seeded = liquidity;
        uint256 supply = token.totalSupply();
        require(token.transfer(distributor, supply / 10));
        require(token.transfer(payer, supply / 10));
        return key.toId();
    }

    function collect() external returns (BalanceDelta) {
        require(msg.sender == controller, "controller only");
        return _modify(0);
    }

    function withdrawAll() external returns (BalanceDelta) {
        require(msg.sender == controller, "controller only");
        return _modify(-int256(uint256(seeded)));
    }

    function poolKey() external view returns (PoolKey memory) {
        return key;
    }

    function _modify(int256 liquidity) private returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(liquidity)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        int256 liquidity = abi.decode(data, (int256));
        (BalanceDelta delta,) = manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, liquidity, 0), "");
        // A fee collect that makes the factory pay means the hook took a share: the PoolFees refusal.
        if (liquidity == 0) require(delta.amount0() >= 0 && delta.amount1() >= 0, "HookTookFees");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);
            require(IERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(uint128(-amount))));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}

/// @notice The launch as the factory performs it on Robinhood Chain: one transaction, the real IMD
/// pair address, the launch's fee tier and spacing, a token-only seed, then trading and fee collection.
contract ConditionalsLaunchTest is Test {
    using StateLibrary for IPoolManager;

    uint256 private constant CHAIN_ID = 4663;
    address private constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    uint24 private constant FEE = 12500;
    int24 private constant SPACING = 60;
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    uint128 private constant SEED_LIQUIDITY = 7e26; // ~700M tokens over the token-only range

    IPoolManager private manager;
    OneCallLaunchFactory private factory;
    Swapper private trader;
    address private distributor = makeAddr("swarm distributor");
    address private payer = makeAddr("paying wallet");

    function setUp() public {
        vm.chainId(CHAIN_ID);
        // The pair token lives on Robinhood Chain; an ERC-20 with no supply stands in at its address.
        vm.etch(IMD, address(new MockERC20("IMD", "IMD", 0)).code);
        manager = IPoolManager(address(new PoolManager(address(this))));
        factory = new OneCallLaunchFactory(manager);
        trader = new Swapper(manager);
        deal(IMD, address(trader), 1_000_000 ether);
    }

    function _launch() private returns (PoolId id, PoolKey memory key) {
        id = factory.launch(_mineSalt(address(factory)), IMD, FEE, SPACING, SEED_LIQUIDITY, distributor, payer);
        key = factory.poolKey();
    }

    function test_oneCallLaunchOpensTheExactConfiguredPool() public {
        (PoolId id, PoolKey memory key) = _launch();
        ConditionalsToken token = factory.token();
        address hook = address(factory.hook());

        // Token metadata: exactly the requested name and 12-character symbol, nothing shortened.
        assertEq(token.name(), "Conditionals");
        assertEq(keccak256(bytes(token.symbol())), keccak256("CONDITIONALS"));
        assertEq(bytes(token.symbol()).length, 12);
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);

        // Allocation: 10% swarm, 10% payer, the 80% remainder seeded or held by the factory.
        assertEq(token.balanceOf(distributor), SUPPLY / 10);
        assertEq(token.balanceOf(payer), SUPPLY / 10);
        assertEq(
            token.balanceOf(address(factory)) + token.balanceOf(address(manager)), SUPPLY * 8 / 10, "80% pool tranche"
        );
        assertGt(token.balanceOf(address(manager)), 0);
        assertEq(IERC20(IMD).balanceOf(address(manager)), 0, "token-only seed needs no pair currency");

        // Pool terms: IMD pair, 1.25% LP fee, spacing 60, this hook, pool ID = hash of the ordered key.
        assertTrue(Currency.unwrap(key.currency0) == IMD || Currency.unwrap(key.currency1) == IMD);
        assertTrue(Currency.unwrap(key.currency0) < Currency.unwrap(key.currency1));
        assertEq(key.fee, FEE);
        assertEq(key.tickSpacing, SPACING);
        assertEq(address(key.hooks), hook);
        assertEq(PoolId.unwrap(id), keccak256(abi.encode(key)));
        (uint160 price,, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(id);
        assertEq(price, TickMath.getSqrtPriceAtTick(0));
        assertEq(protocolFee, 0);
        assertEq(lpFee, FEE);
        assertEq(uint160(hook) & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_INITIALIZE_FLAG);
        assertEq(manager.getLiquidity(id), 0, "price sits just outside the single-sided range");
    }

    function test_buyOnFreshTokenOnlyPoolThenSellAndFactoryCollects() public {
        (PoolId id, PoolKey memory key) = _launch();
        ConditionalsToken token = factory.token();
        address hook = address(factory.hook());
        bool tokenIs0 = Currency.unwrap(key.currency0) == address(token);

        // A buy pays IMD into a manager that holds none and has no hook fee to fund.
        BalanceDelta buy = trader.swap(key, !tokenIs0, 100 ether);
        (int128 tokenOut, int128 imdIn) = tokenIs0 ? (buy.amount0(), buy.amount1()) : (buy.amount1(), buy.amount0());
        assertEq(imdIn, -100 ether);
        assertGt(tokenOut, 0);
        assertEq(token.balanceOf(address(trader)), uint256(uint128(tokenOut)));

        // And the bought tokens sell back for IMD.
        BalanceDelta sell = trader.swap(key, tokenIs0, uint256(uint128(tokenOut)) / 2);
        int128 imdBack = tokenIs0 ? sell.amount1() : sell.amount0();
        assertGt(imdBack, 0);
        assertLt(imdBack, 50 ether, "round trip pays the LP fee");

        // The factory's zero-liquidity collect goes through and yields IMD fees, never a debit.
        BalanceDelta fees = factory.collect();
        int128 imdFees = tokenIs0 ? fees.amount1() : fees.amount0();
        // 1.25% of the 100 IMD buy, minus rounding: the full LP tier reached the position.
        assertApproxEqAbs(uint256(uint128(imdFees)), 1.25 ether, 1e6);
        assertEq(IERC20(IMD).balanceOf(address(factory)), uint256(uint128(imdFees)));
        // The factory unwinds the whole position; nothing is stranded in the manager by the hook.
        factory.withdrawAll();
        assertEq(manager.getLiquidity(id), 0);
        assertLe(token.balanceOf(address(manager)), 10, "only rounding dust remains");
        assertEq(token.balanceOf(hook) + IERC20(IMD).balanceOf(hook) + hook.balance, 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_sellBeforeAnyBuyFindsNoBidsButDoesNotRevert() public {
        (, PoolKey memory key) = _launch();
        ConditionalsToken token = factory.token();
        bool tokenIs0 = Currency.unwrap(key.currency0) == address(token);
        vm.prank(payer);
        token.transfer(address(trader), 1 ether);
        // No IMD is in the pool yet, so a sell fills nothing; the trader keeps the tokens.
        BalanceDelta sell = trader.swap(key, tokenIs0, 1 ether);
        assertEq(BalanceDelta.unwrap(sell), 0);
        assertEq(token.balanceOf(address(trader)), 1 ether);
    }

    function test_launchFailsWhenHookSaltIsMinedForAnotherDeployer() public {
        // A salt mined for the wrong factory lands on wrong permission bits: the whole launch reverts,
        // token and all, rather than opening a pool with an unusable hook.
        bytes32 hash = keccak256(abi.encodePacked(type(ConditionalsHook).creationCode, abi.encode(manager)));
        bytes32 salt;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            if (!HookFlags.matches(_predict(address(factory), salt, hash), HookFlags.BEFORE_INITIALIZE)) break;
        }
        vm.expectRevert();
        factory.launch(salt, IMD, FEE, SPACING, SEED_LIQUIDITY, distributor, payer);
        assertEq(address(factory.token()), address(0));
    }

    function test_launchFailsWhenHookForAnotherManagerIsMined() public {
        // Salt mined for the creation code with a different $poolManager does not match this one's.
        IPoolManager other = IPoolManager(address(new PoolManager(address(this))));
        bytes memory code = abi.encodePacked(type(ConditionalsHook).creationCode, abi.encode(other));
        bytes32 hash = keccak256(code);
        bytes32 ourHash = keccak256(abi.encodePacked(type(ConditionalsHook).creationCode, abi.encode(manager)));
        for (uint256 i;; ++i) {
            bytes32 salt = bytes32(i);
            if (
                HookFlags.matches(_predict(address(factory), salt, hash), HookFlags.BEFORE_INITIALIZE)
                    && !HookFlags.matches(_predict(address(factory), salt, ourHash), HookFlags.BEFORE_INITIALIZE)
            ) {
                vm.expectRevert();
                factory.launch(salt, IMD, FEE, SPACING, SEED_LIQUIDITY, distributor, payer);
                return;
            }
        }
    }

    function test_strangerCannotOpenTheLaunchPoolBeforeTheHookExists() public {
        // Predict the launch pool before the launch: the hook is not yet deployed, so a front-run
        // initialize of the same key reverts, and the factory's launch then succeeds.
        bytes32 salt = _mineSalt(address(factory));
        address predictedHook = _predict(
            address(factory),
            salt,
            keccak256(abi.encodePacked(type(ConditionalsHook).creationCode, abi.encode(manager)))
        );
        address predictedToken = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        (address c0, address c1) = predictedToken < IMD ? (predictedToken, IMD) : (IMD, predictedToken);
        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), FEE, SPACING, IHooks(predictedHook));
        vm.prank(makeAddr("front-runner"));
        vm.expectRevert();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(-50_000));

        (PoolId id, PoolKey memory launched) = _launch();
        assertEq(PoolId.unwrap(id), keccak256(abi.encode(key)), "prediction matched the real launch key");
        assertEq(address(launched.hooks), predictedHook);
    }

    function test_poolOperationFailurePaths() public {
        (PoolId id, PoolKey memory key) = _launch();
        // Zero-amount swap.
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        trader.swapWith(key, SwapParams(true, 0, TickMath.MIN_SQRT_PRICE + 1));
        // Price limit on the wrong side of the current price.
        (uint160 price,,,) = manager.getSlot0(id);
        vm.expectRevert(abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, price, price + 1));
        trader.swapWith(key, SwapParams(true, -1 ether, price + 1));
        // Trading a key that differs from the launch pool in any field reaches an uninitialized pool.
        PoolKey memory wrongFee = PoolKey(key.currency0, key.currency1, 3000, key.tickSpacing, key.hooks);
        vm.expectRevert(IPoolManager.PoolNotInitialized.selector);
        trader.swap(wrongFee, true, 1 ether);
        PoolKey memory noHook = PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, IHooks(address(0)));
        vm.expectRevert(IPoolManager.PoolNotInitialized.selector);
        trader.swap(noHook, true, 1 ether);
        // The launch pool cannot be re-opened at another price.
        vm.expectRevert(abi.encodeWithSelector(Pool.PoolAlreadyInitialized.selector));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(1000));
        // A trader who cannot pay is refused in full; balances do not move.
        Swapper broke = new Swapper(manager);
        bool tokenIs0 = Currency.unwrap(key.currency0) == address(factory.token());
        vm.expectRevert();
        broke.swap(key, !tokenIs0, 1 ether);
        assertEq(factory.token().balanceOf(address(broke)), 0);
    }

    function test_hookHoldsNoValueAndRejectsDirectEth() public {
        (, PoolKey memory key) = _launch();
        address hook = address(key.hooks);
        vm.deal(address(this), 1 ether);
        (bool sent,) = hook.call{value: 1 ether}("");
        assertFalse(sent, "the hook has no rescue path, so it must not accept ETH");
        assertEq(hook.balance, 0);
    }

    function test_hookIsNotOwnedByFactoryOrLaunchWallet() public {
        (, PoolKey memory key) = _launch();
        address hook = address(key.hooks);
        string[8] memory getters = [
            "owner()", "getOwner()", "admin()", "pendingOwner()", "factory()", "operator()", "governance()", "manager()"
        ];
        for (uint256 i; i < getters.length; ++i) {
            (bool ok,) = hook.staticcall(abi.encodeWithSignature(getters[i]));
            assertFalse(ok, getters[i]);
        }
        // AccessControl-style role checks are absent too.
        (bool hasRole,) =
            hook.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", bytes32(0), address(factory)));
        assertFalse(hasRole);
        // The only state is the immutable manager.
        assertEq(address(ConditionalsHook(hook).poolManager()), address(manager));
    }

    function test_runtimeCodeOfHookAndTokenHasNoEscapeHatch() public {
        (, PoolKey memory key) = _launch();
        _assertNoEscapeHatch(address(key.hooks));
        _assertNoEscapeHatch(address(factory.token()));
    }

    function test_hookRefusesEveryUndeclaredCallbackEvenFromTheManager() public {
        (, PoolKey memory key) = _launch();
        address hook = address(key.hooks);
        ModifyLiquidityParams memory mp = ModifyLiquidityParams(-60, 60, 1e18, 0);
        SwapParams memory sp = SwapParams(true, -1, TickMath.MIN_SQRT_PRICE + 1);
        bytes[9] memory calls = [
            abi.encodeCall(IHooks.afterInitialize, (address(factory), key, 1 << 96, 0)),
            abi.encodeCall(IHooks.beforeAddLiquidity, (address(factory), key, mp, "")),
            abi.encodeCall(
                IHooks.afterAddLiquidity, (address(factory), key, mp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "")
            ),
            abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(factory), key, mp, "")),
            abi.encodeCall(
                IHooks.afterRemoveLiquidity, (address(factory), key, mp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "")
            ),
            abi.encodeCall(IHooks.beforeSwap, (address(factory), key, sp, "")),
            abi.encodeCall(IHooks.afterSwap, (address(factory), key, sp, BalanceDelta.wrap(0), "")),
            abi.encodeCall(IHooks.beforeDonate, (address(factory), key, 1, 1, "")),
            abi.encodeCall(IHooks.afterDonate, (address(factory), key, 1, 1, ""))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(address(manager));
            (bool ok,) = hook.call(calls[i]);
            assertFalse(ok);
        }
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_beforeInitializeRejectsEveryCallerButTheManager(address caller, address sender, uint160 price)
        public
    {
        vm.assume(caller != address(manager));
        (, PoolKey memory key) = _launch();
        ConditionalsHook hook = factory.hook();
        vm.prank(caller);
        vm.expectRevert(ConditionalsHook.OnlyPoolManager.selector);
        hook.beforeInitialize(sender, key, price);
        vm.prank(address(manager));
        assertEq(hook.beforeInitialize(sender, key, price), IHooks.beforeInitialize.selector);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_buyRoundTripNeverProfitsTheTrader(uint256 rawIn) public {
        (, PoolKey memory key) = _launch();
        ConditionalsToken token = factory.token();
        bool tokenIs0 = Currency.unwrap(key.currency0) == address(token);
        uint256 amountIn = bound(rawIn, 1, 1_000_000 ether);
        BalanceDelta buy = trader.swap(key, !tokenIs0, amountIn);
        int128 got = tokenIs0 ? buy.amount0() : buy.amount1();
        if (got == 0) return; // a 1-wei buy can round to nothing; it still paid
        BalanceDelta sell = trader.swap(key, tokenIs0, uint256(uint128(got)));
        int128 back = tokenIs0 ? sell.amount1() : sell.amount0();
        assertLt(uint256(uint128(back)), amountIn, "buy-then-sell returned at least what was paid");
        assertEq(IERC20(IMD).balanceOf(address(trader)), 1_000_000 ether - amountIn + uint256(uint128(back)));
    }

    function _assertNoEscapeHatch(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xff, "SELFDESTRUCT");
                assertTrue(op != 0xf4, "DELEGATECALL");
                assertTrue(op != 0xf2, "CALLCODE");
            }
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }

    function _mineSalt(address deployer) private view returns (bytes32) {
        bytes32 hash = keccak256(abi.encodePacked(type(ConditionalsHook).creationCode, abi.encode(manager)));
        for (uint256 i; i < 200_000; ++i) {
            if (HookFlags.matches(_predict(deployer, bytes32(i), hash), HookFlags.BEFORE_INITIALIZE)) {
                return bytes32(i);
            }
        }
        revert("no salt");
    }

    function _predict(address deployer, bytes32 salt, bytes32 hash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, hash)))));
    }
}
