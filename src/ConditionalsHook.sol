// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice Minimal launch-policy hook: acknowledges initialization without changing pool economics.
/// @dev No admin, swap callbacks, fee overrides, custom deltas, or custody. See README assumptions.
contract ConditionalsHook {
    error InvalidPoolManager();
    error OnlyPoolManager();

    IPoolManager public immutable poolManager;

    /// @param poolManager_ The chain's PoolManager, supplied by the launch as $poolManager.
    constructor(IPoolManager poolManager_) {
        if (address(poolManager_) == address(0)) revert InvalidPoolManager();
        poolManager = poolManager_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
    }

    /// @dev The factory deploys the hook and initializes its pool atomically. This callback makes
    /// initialization fail while the predicted hook address has no code. It imposes no extra gates.
    function beforeInitialize(address, PoolKey calldata, uint160) external view returns (bytes4) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        return IHooks.beforeInitialize.selector;
    }
}
