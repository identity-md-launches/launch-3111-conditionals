// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The launch token. The factory receives the complete, fixed supply.
/// @dev Allocation is performed by the launch factory, not by this contract.
contract ConditionalsToken is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("Conditionals", "CONDITIONALS") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
