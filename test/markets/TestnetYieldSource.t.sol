// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    AssetMarketFaucetToken,
    AssetMarketTestYieldSource
} from "../../script/DeployAssetMarketsTestnet.s.sol";

contract TestnetYieldSourceTest is Test {
    AssetMarketFaucetToken token;
    AssetMarketTestYieldSource source;
    address other = address(0xBEEF);

    function setUp() public {
        vm.chainId(31337);
        token = new AssetMarketFaucetToken("Test", "T", 6);
        source = new AssetMarketTestYieldSource();
        token.mint(address(this), 100e6);
        token.approve(address(source), 100e6);
        source.deposit(address(token), 100e6);
        token.mint(other, 20e6);
        vm.startPrank(other);
        token.approve(address(source), 20e6);
        source.deposit(address(token), 20e6);
        vm.stopPrank();
    }

    function test_recallCapsRoundingBufferAndPreservesOtherConsumer() public {
        assertEq(source.withdraw(address(token), 100e6 + 1, address(this)), 100e6);
        assertEq(token.balanceOf(address(this)), 100e6);
        assertEq(source.balances(address(token), address(this)), 0);
        assertEq(source.balances(address(token), other), 20e6);
        assertEq(source.totalAssets(address(token)), 20e6);
        assertEq(token.balanceOf(address(source)), 20e6);
        assertEq(source.withdraw(address(token), 1, address(this)), 0);
    }

    function testFuzz_withdrawNeverExceedsCallerPosition(uint256 requested) public {
        uint256 expected = requested > 100e6 ? 100e6 : requested;
        assertEq(source.withdraw(address(token), requested, address(this)), expected);
        assertEq(source.balances(address(token), other), 20e6);
        assertEq(source.totalAssets(address(token)), 120e6 - expected);
    }
}
