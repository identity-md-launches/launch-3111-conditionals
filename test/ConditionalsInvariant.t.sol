// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ConditionalsToken} from "../src/ConditionalsToken.sol";

contract TokenHandler is Test {
    ConditionalsToken public immutable token;
    address[4] public actors;

    constructor(ConditionalsToken token_) {
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("token test actor", i)))));
        }
    }

    function move(uint8 fromSeed, uint8 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function spend(uint8 fromSeed, uint8 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        vm.prank(from);
        token.approve(to, amount);
        vm.prank(to);
        token.transferFrom(from, to, amount);
    }
}

contract ConditionalsInvariantTest is StdInvariant, Test {
    ConditionalsToken private token;
    TokenHandler private handler;

    function setUp() public {
        token = new ConditionalsToken();
        handler = new TokenHandler(token);
        token.transfer(handler.actors(0), token.totalSupply());
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = TokenHandler.move.selector;
        selectors[1] = TokenHandler.spend.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_supplyAndMetadataNeverChange() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, 1_000_000_000 ether);
        assertEq(token.totalSupply(), sum);
        assertEq(token.symbol(), "CONDITIONALS");
        assertEq(token.name(), "Conditionals");
        assertEq(token.decimals(), 18);
    }
}
