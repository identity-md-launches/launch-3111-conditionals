// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
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
import {PoolActor} from "./mocks/PoolActor.sol";
import {Swapper} from "./mocks/Swapper.sol";

/// @dev Drives the hooked launch pool and an identical hookless twin with the same random actions.
/// Every LP and trader is a separate contract holding its own funds, so it pays only for itself.
contract PoolHandler is Test {
    using StateLibrary for IPoolManager;

    uint256 internal constant N_LP = 3;
    uint256 internal constant N_TRADER = 2;
    uint256 internal constant N_RANGE = 4;

    IPoolManager public immutable manager;
    ConditionalsToken public immutable token;
    MockERC20 public immutable pair;
    PoolKey internal hooked;
    PoolKey internal twin;

    /// @dev Separate, identically funded actors per pool so the two pools' states stay mirrored.
    PoolActor[N_LP] public lps;
    PoolActor[N_LP] public twinLps;
    Swapper[N_TRADER] public traders;
    Swapper[N_TRADER] public twinTraders;
    int24[N_RANGE] internal lowers;
    int24[N_RANGE] internal uppers;

    /// @dev ghost: liquidity each LP holds in each range (identical in both pools by construction).
    mapping(uint256 => mapping(uint256 => uint128)) public ghostLiquidity;
    uint256 public mismatches;
    uint256 public okSwaps;
    uint256 public okModifies;
    uint256 public negativeCollects;

    constructor(IPoolManager manager_, ConditionalsToken token_, MockERC20 pair_, PoolKey memory hooked_) {
        manager = manager_;
        token = token_;
        pair = pair_;
        hooked = hooked_;
        twin = PoolKey(hooked_.currency0, hooked_.currency1, hooked_.fee, hooked_.tickSpacing, IHooks(address(0)));
        for (uint256 i; i < N_LP; ++i) {
            lps[i] = new PoolActor(manager_);
            twinLps[i] = new PoolActor(manager_);
        }
        for (uint256 i; i < N_TRADER; ++i) {
            traders[i] = new Swapper(manager_);
            twinTraders[i] = new Swapper(manager_);
        }
        int24 s = hooked_.tickSpacing;
        lowers = [TickMath.minUsableTick(s), int24(-600), int24(-6000), int24(60)];
        uppers = [TickMath.maxUsableTick(s), int24(600), int24(-60), int24(6000)];
    }

    function twinKey() external view returns (PoolKey memory) {
        return twin;
    }

    function hookedKey() external view returns (PoolKey memory) {
        return hooked;
    }

    function range(uint256 r) external view returns (int24, int24) {
        return (lowers[r], uppers[r]);
    }

    function addLiquidity(uint256 lpSeed, uint256 rangeSeed, uint256 amountSeed) external {
        uint256 lp = lpSeed % N_LP;
        uint256 r = rangeSeed % N_RANGE;
        uint128 liquidity = uint128(bound(amountSeed, 1e12, 1e21));
        // An add may net positive: v4 pays a position's accrued fees out on any modification.
        (bool ok,,) = _modifyBoth(lp, r, int256(uint256(liquidity)));
        if (ok) ghostLiquidity[lp][r] += liquidity;
    }

    function removeLiquidity(uint256 lpSeed, uint256 rangeSeed, uint256 amountSeed) external {
        uint256 lp = lpSeed % N_LP;
        uint256 r = rangeSeed % N_RANGE;
        uint128 held = ghostLiquidity[lp][r];
        if (held == 0) return;
        uint128 liquidity = uint128(bound(amountSeed, 1, held));
        (bool ok, BalanceDelta a,) = _modifyBoth(lp, r, -int256(uint256(liquidity)));
        assertTrue(ok, "an LP could not withdraw liquidity it holds");
        ghostLiquidity[lp][r] -= liquidity;
        assertGe(a.amount0(), 0);
        assertGe(a.amount1(), 0);
    }

    /// @dev The launch factory's fee collect: a zero liquidity change, which v4 runs as a removal.
    function collect(uint256 lpSeed, uint256 rangeSeed) external {
        uint256 lp = lpSeed % N_LP;
        uint256 r = rangeSeed % N_RANGE;
        if (ghostLiquidity[lp][r] == 0) return;
        (bool ok, BalanceDelta a,) = _modifyBoth(lp, r, 0);
        assertTrue(ok, "a fee collect was refused");
        if (a.amount0() < 0 || a.amount1() < 0) ++negativeCollects;
    }

    function swap(uint256 traderSeed, bool zeroForOne, bool exactInput, uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 1e21);
        SwapParams memory params = SwapParams(
            zeroForOne,
            exactInput ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        uint256 t = traderSeed % N_TRADER;
        (bool okH, bytes memory retH) = address(traders[t]).call(abi.encodeCall(Swapper.swapWith, (hooked, params)));
        (bool okT, bytes memory retT) = address(twinTraders[t]).call(abi.encodeCall(Swapper.swapWith, (twin, params)));
        if (okH != okT || (okH && keccak256(retH) != keccak256(retT))) ++mismatches;
        if (okH) ++okSwaps;
    }

    function donate(uint256 lpSeed, uint256 a0, uint256 a1) external {
        a0 = bound(a0, 0, 1e18);
        a1 = bound(a1, 0, 1e18);
        uint256 lp = lpSeed % N_LP;
        (bool okH, bytes memory retH) = address(lps[lp]).call(abi.encodeCall(PoolActor.donate, (hooked, a0, a1)));
        (bool okT, bytes memory retT) = address(twinLps[lp]).call(abi.encodeCall(PoolActor.donate, (twin, a0, a1)));
        if (okH != okT || (okH && keccak256(retH) != keccak256(retT))) ++mismatches;
    }

    /// @dev Used after each run: every LP removes everything it holds from both pools.
    function drainAll() external returns (bool allOk) {
        allOk = true;
        for (uint256 lp; lp < N_LP; ++lp) {
            for (uint256 r; r < N_RANGE; ++r) {
                uint128 held = ghostLiquidity[lp][r];
                if (held == 0) continue;
                (bool ok,,) = _modifyBoth(lp, r, -int256(uint256(held)));
                if (!ok) allOk = false;
                else ghostLiquidity[lp][r] = 0;
            }
        }
    }

    function _modifyBoth(uint256 lp, uint256 r, int256 liquidity)
        internal
        returns (bool ok, BalanceDelta onHooked, BalanceDelta onTwin)
    {
        ModifyLiquidityParams memory params = ModifyLiquidityParams(lowers[r], uppers[r], liquidity, 0);
        (bool okH, bytes memory retH) = address(lps[lp]).call(abi.encodeCall(PoolActor.modify, (hooked, params)));
        (bool okT, bytes memory retT) = address(twinLps[lp]).call(abi.encodeCall(PoolActor.modify, (twin, params)));
        if (okH != okT || (okH && keccak256(retH) != keccak256(retT))) ++mismatches;
        ok = okH && okT;
        if (okH) onHooked = abi.decode(retH, (BalanceDelta));
        if (okT) onTwin = abi.decode(retT, (BalanceDelta));
        if (ok) ++okModifies;
    }
}

/// @notice Stateful properties of the launch pool under random LP, trade, collect and donate sequences:
/// the hook never changes pool economics (twin pool agrees exactly), never holds value, the supply and
/// pair balances are conserved, the fee tier never moves, and every LP can always exit.
contract ConditionalsPoolInvariantTest is StdInvariant, Test {
    using StateLibrary for IPoolManager;

    uint256 private constant FUNDS = 50_000_000 ether;

    IPoolManager private manager;
    ConditionalsToken private token;
    MockERC20 private pair;
    ConditionalsHook private hook;
    PoolHandler private handler;
    PoolKey private hooked;
    PoolKey private twin;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new ConditionalsToken();
        pair = new MockERC20("Test IMD", "IMD", 1_000_000_000 ether);
        bytes32 hash = keccak256(abi.encodePacked(type(ConditionalsHook).creationCode, abi.encode(manager)));
        bytes32 salt;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (HookFlags.matches(predicted, HookFlags.BEFORE_INITIALIZE)) break;
        }
        hook = new ConditionalsHook{salt: salt}(manager);
        (address a, address b) =
            address(token) < address(pair) ? (address(token), address(pair)) : (address(pair), address(token));
        hooked = PoolKey(Currency.wrap(a), Currency.wrap(b), 12500, 60, IHooks(address(hook)));
        handler = new PoolHandler(manager, token, pair, hooked);
        twin = handler.twinKey();
        manager.initialize(hooked, TickMath.getSqrtPriceAtTick(0));
        manager.initialize(twin, TickMath.getSqrtPriceAtTick(0));
        for (uint256 i; i < 3; ++i) {
            _fund(address(handler.lps(i)));
            _fund(address(handler.twinLps(i)));
        }
        for (uint256 i; i < 2; ++i) {
            _fund(address(handler.traders(i)));
            _fund(address(handler.twinTraders(i)));
        }
        // Seed one full-range position so trades have something to fill against from the start.
        handler.addLiquidity(0, 0, 1e21);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = PoolHandler.addLiquidity.selector;
        selectors[1] = PoolHandler.removeLiquidity.selector;
        selectors[2] = PoolHandler.collect.selector;
        selectors[3] = PoolHandler.swap.selector;
        selectors[4] = PoolHandler.donate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function _fund(address to) private {
        token.transfer(to, FUNDS);
        pair.transfer(to, FUNDS);
    }

    function _sum(IERC20 asset) private view returns (uint256 total) {
        for (uint256 i; i < 3; ++i) {
            total += asset.balanceOf(address(handler.lps(i))) + asset.balanceOf(address(handler.twinLps(i)));
        }
        for (uint256 i; i < 2; ++i) {
            total += asset.balanceOf(address(handler.traders(i))) + asset.balanceOf(address(handler.twinTraders(i)));
        }
        total += asset.balanceOf(address(manager)) + asset.balanceOf(address(this)) + asset.balanceOf(address(hook));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_hookedPoolBehavesExactlyLikeItsHooklessTwin() public view {
        assertEq(handler.mismatches(), 0, "the hooked pool diverged from the hookless pool");
        (uint160 pH, int24 tH, uint24 protoH, uint24 feeH) = manager.getSlot0(hooked.toId());
        (uint160 pT, int24 tT, uint24 protoT, uint24 feeT) = manager.getSlot0(twin.toId());
        assertEq(pH, pT);
        assertEq(tH, tT);
        assertEq(protoH, protoT);
        assertEq(feeH, feeT);
        assertEq(manager.getLiquidity(hooked.toId()), manager.getLiquidity(twin.toId()));
        (uint256 g0H, uint256 g1H) = manager.getFeeGrowthGlobals(hooked.toId());
        (uint256 g0T, uint256 g1T) = manager.getFeeGrowthGlobals(twin.toId());
        assertEq(g0H, g0T);
        assertEq(g1H, g1T);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_feeTierAndPositionsMatchTheGhostLedger() public view {
        (,, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(hooked.toId());
        assertEq(lpFee, 12500, "the 1.25% LP fee changed");
        assertEq(protocolFee, 0);
        for (uint256 lp; lp < 3; ++lp) {
            for (uint256 r; r < 4; ++r) {
                (int24 lower, int24 upper) = handler.range(r);
                (uint128 liquidity,,) =
                    manager.getPositionInfo(hooked.toId(), address(handler.lps(lp)), lower, upper, bytes32(0));
                assertEq(liquidity, handler.ghostLiquidity(lp, r));
            }
        }
        assertEq(handler.negativeCollects(), 0, "a fee collect made the LP pay");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_valueIsConservedAndTheHookHoldsNothing() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether, "fixed supply changed");
        assertEq(_sum(IERC20(address(token))), token.totalSupply(), "launch token leaked or was created");
        assertEq(_sum(IERC20(address(pair))), pair.totalSupply(), "pair currency leaked or was created");
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(pair.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), hooked.currency0.toId()), 0, "hook holds ERC-6909 claims");
        assertEq(manager.balanceOf(address(hook), hooked.currency1.toId()), 0, "hook holds ERC-6909 claims");
        assertEq(token.symbol(), "CONDITIONALS");
    }

    /// @dev At the end of every run all LPs exit both pools; nothing may block it, and only rounding
    /// dust (always in the pool's favour) may stay behind in the manager.
    function afterInvariant() public {
        assertTrue(handler.drainAll(), "an LP could not exit");
        assertEq(manager.getLiquidity(hooked.toId()), 0);
        assertEq(manager.getLiquidity(twin.toId()), 0);
        // Upper bound on rounding: a few wei per successful operation, over two pools.
        uint256 dustBound = 8 * (handler.okModifies() + handler.okSwaps() + 1);
        assertLe(token.balanceOf(address(manager)), dustBound, "launch token stranded in the manager");
        assertLe(pair.balanceOf(address(manager)), dustBound, "pair currency stranded in the manager");
    }
}
