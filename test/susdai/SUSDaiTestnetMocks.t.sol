// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {SUSDaiTestnetSpokePool, SUSDaiTestnetToken} from "../../src/testnet/SUSDaiTestnetMocks.sol";

contract SUSDaiTestnetMocksTest is Test {
    SUSDaiTestnetToken homeToken;
    SUSDaiTestnetToken remoteToken;
    SUSDaiTestnetSpokePool origin;
    SUSDaiTestnetSpokePool destination;

    address owner = address(0x0AD01);
    address relayer = address(0xC0FFEE);
    address depositor = address(0xD3F0517);
    address recipient = address(0xA11CE);

    function setUp() public {
        homeToken = new SUSDaiTestnetToken("Home", "HOME", 6);
        remoteToken = new SUSDaiTestnetToken("Remote", "REMOTE", 6);
        origin = new SUSDaiTestnetSpokePool(owner, relayer);
        destination = new SUSDaiTestnetSpokePool(owner, relayer);
        homeToken.mint(depositor, 10_000e6);
        vm.warp(1_800_000_000);
    }

    function _deposit(uint32 fillDeadline) internal {
        vm.startPrank(depositor);
        homeToken.approve(address(origin), 1_000e6);
        origin.depositV3(
            depositor,
            recipient,
            address(homeToken),
            address(remoteToken),
            1_000e6,
            999_400_000,
            421614,
            address(0),
            uint32(block.timestamp),
            fillDeadline,
            0,
            ""
        );
        vm.stopPrank();
    }

    function test_fill_mintsExactOutputAndCannotReplay() public {
        uint32 deadline = uint32(block.timestamp + 1 hours);
        _deposit(deadline);
        SUSDaiTestnetSpokePool.RelayData memory relay = SUSDaiTestnetSpokePool.RelayData({
            inputToken: address(homeToken),
            outputToken: address(remoteToken),
            inputAmount: 1_000e6,
            outputAmount: 999_400_000,
            originChainId: 46630,
            depositId: 0,
            fillDeadline: deadline,
            depositor: depositor,
            recipient: recipient
        });

        vm.prank(relayer);
        destination.fill(relay);
        assertEq(remoteToken.balanceOf(recipient), 999_400_000);
        assertTrue(destination.filled(46630, 0));

        vm.prank(relayer);
        vm.expectRevert(SUSDaiTestnetSpokePool.AlreadyFilled.selector);
        destination.fill(relay);
    }

    function test_refund_requiresExpiryAndReturnsExactEscrowOnce() public {
        uint32 deadline = uint32(block.timestamp + 1 hours);
        _deposit(deadline);
        assertEq(homeToken.balanceOf(depositor), 9_000e6);

        vm.prank(relayer);
        vm.expectRevert(SUSDaiTestnetSpokePool.DepositNotExpired.selector);
        origin.refund(0);
        vm.warp(deadline + 1);
        vm.prank(owner);
        origin.refund(0);
        assertEq(homeToken.balanceOf(depositor), 10_000e6);

        vm.prank(owner);
        vm.expectRevert(SUSDaiTestnetSpokePool.UnknownDeposit.selector);
        origin.refund(0);
    }
}
