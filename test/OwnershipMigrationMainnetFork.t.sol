// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

interface IOwnable2Step {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface IBeacon {
    function implementation() external view returns (address);
    function upgradeTo(address newImplementation) external;
}

interface ISafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function VERSION() external view returns (string memory);
    function nonce() external view returns (uint256);
}

interface IProtocolGuard {
    function guardian() external view returns (address);
    function isPaused(address target) external view returns (bool);
    function pauseTarget(address target) external;
    function unpauseTarget(address target) external;
}

interface IReserve {
    function redemptionFeeBps() external view returns (uint16);
    function setRedemptionFee(uint16 bps) external;
    function pendingRedemptionFeeBps() external view returns (uint16);
    function FEE_INCREASE_DELAY() external view returns (uint64);
    function commitRedemptionFee() external;
}

/// @title OwnershipMigrationMainnetFork
/// @notice The custody migration is DONE. This pins the end state against live mainnet.
///
/// @dev    This suite used to rehearse the handover, deploying a throwaway Safe from the
///         canonical factory and driving it with real 2-of-3 signatures. That was the right
///         test while the migration was ahead of us and the question was "can this work". It
///         is the wrong test now: the migration has happened, the rehearsal cannot be
///         replayed against a chain where every transfer is already complete, and a test that
///         deploys its own Safe proves nothing about the one that actually holds the
///         protocol.
///
///         So the question changes from "can we hand over" to "did we, completely, and is
///         anything still reachable by the retired key". That is what an auditor will ask,
///         and it is answerable entirely from live state.
///
///         The signing path is not re-proven here because the chain already proves it: the
///         Safe executed two batches to accept twelve handles, and its `nonce` records them.
contract OwnershipMigrationMainnetForkTest is Test {
    uint256 constant CHAIN_ID = 4663;

    /// @dev The retired deployer. After this migration it owns nothing and is only still the
    ///      guardian, which is deliberate and asserted below.
    address constant DEPLOYER = 0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9;

    /// @dev The 2-of-3 Safe that now owns the protocol.
    address constant SAFE = 0x28569c1716EF81f307d666A1EC08bDAE92AC0373;

    address constant GUARD = 0x013D1974F8215a12280e6b9a33F9732277F38C0e;
    address constant RESERVE_SUSDAI = 0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2;
    address constant FEE_HOOK = 0xc9932584c5154e4F58313a2e5423522E74e540Cc;

    /// @dev Every two-step handle, in the order the migration moved them.
    function _twoStep() internal pure returns (address[12] memory handles) {
        handles = [
            0xBd02B0f3253F31dD02A752582e7b8974589333f7, // StrategyGroupRegistry
            0xbE2fb491C37F19E723F86A8cAcA625B4Ba75a5E7, // gen-4 factory, abandoned
            0x2F26F8fE6c8f6BA3F72D062f1a4E64fFe596963C, // LaunchLocker
            0x013D1974F8215a12280e6b9a33F9732277F38C0e, // ProtocolGuard
            0x8e4E5e5EE25DF4721D845600F82bf2Bca48Fa358, // MorphoBlueYieldSource
            0x460f319E43428387bff58ec262C992Ec7DA22fDc, // SUSDaiYieldSource
            0x95fe000285DA7797cC01394cCc410628B26e898d, // LaunchFactory
            0x7553919210B172438853C3694Fd88fAfD4bE3Eb4, // MarketRouter
            0xc9932584c5154e4F58313a2e5423522E74e540Cc, // ProtocolFeeHook
            0x22AA61c589B90731752236c07d1455D0065bfc79, // AssetMarketFactory
            0xdB485351d953F10FAA7c820B7648f6E91d9Cd9F3, // SharedReservePool, USDG/Morpho
            0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2 // SharedReservePool, sUSDai
        ];
    }

    /// @dev The four beacons. Plain `Ownable`: transferred in one step, irreversibly.
    function _beacons() internal pure returns (address[4] memory handles) {
        handles = [
            0x65876276feE875e1A120F63575150593E6AEa0d3, // brandFeeVault
            0xb6b86f5A01d8c04f68f827532C8aCE9458Db57a6, // lpRewardDistributor
            0x1964b405C09CF252d835A80556536C86dcbE105F, // pooledBrandToken
            0xf8b758dfb9d22448Ab13C7FcC1f23b75A998C34E // poolBrandTreasury
        ];
    }

    function setUp() public {
        vm.skip(block.chainid != CHAIN_ID);
    }

    /// @notice Every handle, both kinds, is the Safe's. This is the headline claim of the
    ///         migration and the one an auditor will check first.
    function test_fork_everySingleHandleIsOwnedByTheSafe() public view {
        address[12] memory twoStep = _twoStep();
        for (uint256 i; i < twoStep.length; ++i) {
            assertEq(IOwnable2Step(twoStep[i]).owner(), SAFE, "a two-step handle is not the Safe's");
        }

        address[4] memory beacons = _beacons();
        for (uint256 i; i < beacons.length; ++i) {
            assertEq(IOwnable(beacons[i]).owner(), SAFE, "a beacon is not the Safe's");
        }
    }

    /// @notice No nomination is left anywhere. A stale `pendingOwner` is a live claim on the
    ///         protocol that anyone holding that address could accept later, at any time.
    function test_fork_noNominationIsLeftOutstanding() public view {
        address[12] memory twoStep = _twoStep();
        for (uint256 i; i < twoStep.length; ++i) {
            assertEq(
                IOwnable2Step(twoStep[i]).pendingOwner(),
                address(0),
                "a handle still carries an acceptable nomination"
            );
        }
    }

    /// @notice The retired key is powerless. Asserted by attempting real owner-only calls
    ///         rather than by reading `owner()` again, because what matters is that the call
    ///         reverts, not that a getter disagrees with it.
    function test_fork_theRetiredDeployerCanNoLongerGovernAnything() public {
        uint16 fee = IReserve(RESERVE_SUSDAI).redemptionFeeBps();

        vm.prank(DEPLOYER);
        vm.expectRevert();
        IReserve(RESERVE_SUSDAI).setRedemptionFee(fee + 1);

        vm.prank(DEPLOYER);
        vm.expectRevert();
        IProtocolGuard(GUARD).unpauseTarget(FEE_HOOK);

        // And the irreversible ones. A beacon still answering the old key would mean the code
        // behind every brand token was never actually handed over.
        address[4] memory beacons = _beacons();
        for (uint256 i; i < beacons.length; ++i) {
            vm.prank(DEPLOYER);
            vm.expectRevert();
            IOwnable(beacons[i]).transferOwnership(DEPLOYER);
        }
    }

    /// @notice The Safe can actually govern. An end state where nobody can act would be worse
    ///         than the one we started from, so this exercises the powers, not just the flags.
    function test_fork_theSafeCanGovernEveryClassOfHandle() public {
        // A two-step proxy: an increase still only SCHEDULES, so the announced delay survived
        // the handover rather than being bypassed by the new owner.
        uint16 fee = IReserve(RESERVE_SUSDAI).redemptionFeeBps();
        vm.prank(SAFE);
        IReserve(RESERVE_SUSDAI).setRedemptionFee(fee + 5);
        assertEq(IReserve(RESERVE_SUSDAI).redemptionFeeBps(), fee, "the live fee did not jump");
        assertEq(IReserve(RESERVE_SUSDAI).pendingRedemptionFeeBps(), fee + 5, "it was announced");

        // A beacon: the Safe can move the implementation behind every clone of a type. Pointed
        // at the current implementation so the call proves authority without changing code.
        address beacon = _beacons()[0];
        address current = IBeacon(beacon).implementation();
        vm.prank(SAFE);
        IBeacon(beacon).upgradeTo(current);
        assertEq(IBeacon(beacon).implementation(), current, "the beacon still answers its owner");
    }

    /// @notice The guardian is NOT the Safe and must never be. Pausing is incident response:
    ///         it has to work with one key, immediately, with nobody else awake.
    function test_fork_theGuardianIsStillAHotKeyThatActsAlone() public {
        address guardian = IProtocolGuard(GUARD).guardian();
        assertTrue(guardian != SAFE, "the guardian must not be the multisig");

        vm.prank(guardian);
        IProtocolGuard(GUARD).pauseTarget(FEE_HOOK);
        assertTrue(IProtocolGuard(GUARD).isPaused(FEE_HOOK), "one hot key can still halt a target");

        // Resuming is the slow path on purpose: only the owner, which is now the Safe. A
        // stolen guardian key therefore buys a denial of service and nothing more.
        vm.prank(guardian);
        vm.expectRevert();
        IProtocolGuard(GUARD).unpauseTarget(FEE_HOOK);

        vm.prank(SAFE);
        IProtocolGuard(GUARD).unpauseTarget(FEE_HOOK);
        assertFalse(IProtocolGuard(GUARD).isPaused(FEE_HOOK), "and the Safe can resume");
    }

    /// @notice The Safe itself is the configuration we intended, read from the chain rather
    ///         than from anything written in this repository.
    function test_fork_theSafeIsATwoOfThreeThatHasAlreadyTransacted() public view {
        ISafe safe = ISafe(SAFE);
        assertEq(safe.getThreshold(), 2, "threshold is 2");
        assertEq(safe.getOwners().length, 3, "of three signers");
        assertGt(safe.nonce(), 0, "and it has executed before, so the signers demonstrably work");

        address[] memory signers = safe.getOwners();
        for (uint256 i; i < signers.length; ++i) {
            assertTrue(signers[i] != DEPLOYER, "the retired key must not be a signer");
            for (uint256 j = i + 1; j < signers.length; ++j) {
                assertTrue(signers[i] != signers[j], "signers are distinct");
            }
        }
    }
}
