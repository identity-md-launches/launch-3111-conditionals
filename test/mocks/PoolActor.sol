// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Test-only actor funded before it calls the manager; also holds the test LP position.
contract PoolActor is IUnlockCallback {
    IPoolManager public immutable manager;
    address public immutable controller;

    constructor(IPoolManager manager_) {
        manager = manager_;
        controller = msg.sender;
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory params) external returns (BalanceDelta) {
        require(msg.sender == controller, "controller only");
        return abi.decode(manager.unlock(abi.encode(uint8(0), key, abi.encode(params))), (BalanceDelta));
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        require(msg.sender == controller, "controller only");
        return abi.decode(manager.unlock(abi.encode(uint8(1), key, abi.encode(params))), (BalanceDelta));
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external returns (BalanceDelta) {
        require(msg.sender == controller, "controller only");
        return abi.decode(manager.unlock(abi.encode(uint8(2), key, abi.encode(amount0, amount1))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, PoolKey memory key, bytes memory params) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta delta;
        if (action == 0) {
            (delta,) = manager.modifyLiquidity(key, abi.decode(params, (ModifyLiquidityParams)), "");
        } else if (action == 1) {
            delta = manager.swap(key, abi.decode(params, (SwapParams)), "");
        } else {
            (uint256 a0, uint256 a1) = abi.decode(params, (uint256, uint256));
            delta = manager.donate(key, a0, a1, "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);
            require(IERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(-int256(amount))));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}
