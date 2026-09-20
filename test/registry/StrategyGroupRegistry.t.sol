// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import {StrategyGroupRegistry} from "../../src/registry/StrategyGroupRegistry.sol";

contract MockGroupPool {
    address public asset;
    address public yieldSource;

    constructor(address asset_, address yieldSource_) {
        asset = asset_;
        yieldSource = yieldSource_;
    }

    function setYieldSource(address next) external {
        yieldSource = next;
    }
}

contract MockGroupFactory {
    address public reservePool;
    mapping(address => bool) public approvedReservePool;

    constructor(address reservePool_) {
        reservePool = reservePool_;
    }

    function approveReserve(address reserve) external {
        approvedReservePool[reserve] = true;
    }
}

contract MockGroupRouter {
    address public factory;
    address public reservePool;

    constructor(address factory_, address reservePool_) {
        factory = factory_;
        reservePool = reservePool_;
    }
}

contract MockGroupZapper {
    address public factory;
    address public reservePool;

    constructor(address factory_, address reservePool_) {
        factory = factory_;
        reservePool = reservePool_;
    }
}

/// @dev The registry with one appended storage variable and a version marker, used to prove an
///      upgrade both keeps the existing group table readable and can extend the layout.
contract StrategyGroupRegistryV2 is StrategyGroupRegistry {
    string public upgradeNote;

    function setUpgradeNote(string calldata note) external {
        upgradeNote = note;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract StrategyGroupRegistryTest is Test {
    bytes32 internal constant GROUP = keccak256("susdai");
    bytes32 internal constant POLICY = keccak256("cross-chain-buffered-v1");

    StrategyGroupRegistry internal registry;
    MockGroupPool internal pool;
    address internal asset;
    address internal yieldSource;

    function setUp() public {
        asset = address(new MockGroupFactory(address(0)));
        yieldSource = address(new MockGroupFactory(address(0)));
        pool = new MockGroupPool(asset, yieldSource);
        registry = StrategyGroupRegistry(
            address(
                new ERC1967Proxy(
                    address(new StrategyGroupRegistry()),
                    abi.encodeCall(StrategyGroupRegistry.initialize, (address(this)))
                )
            )
        );
    }

    function input() internal view returns (StrategyGroupRegistry.GroupInput memory value) {
        value = StrategyGroupRegistry.GroupInput({
            reservePool: address(pool),
            yieldSource: yieldSource,
            factory: address(0),
            router: address(0),
            zapper: address(0),
            policyId: POLICY,
            active: true,
            name: "sUSDai reserve",
            strategy: "sUSDai on Arbitrum"
        });
    }

    function test_setGroupPublishesStandaloneGroup() public {
        StrategyGroupRegistry.GroupInput memory value = input();
        registry.setGroup(GROUP, value);

        StrategyGroupRegistry.Group memory stored = registry.group(GROUP);
        assertEq(stored.reservePool, address(pool));
        assertEq(stored.asset, asset);
        assertEq(stored.yieldSource, yieldSource);
        assertEq(stored.factory, address(0));
        assertEq(stored.router, address(0));
        assertEq(stored.zapper, address(0));
        assertEq(stored.policyId, POLICY);
        assertTrue(stored.active);
        assertEq(stored.name, "sUSDai reserve");
        assertEq(stored.strategy, "sUSDai on Arbitrum");
        assertTrue(registry.exists(GROUP));
        assertEq(registry.groupCount(), 1);
        assertEq(registry.groupIdAt(0), GROUP);
    }

    function test_setGroupPublishesValidatedMarketStack() public {
        MockGroupFactory factory = new MockGroupFactory(address(pool));
        MockGroupRouter router = new MockGroupRouter(address(factory), address(pool));
        MockGroupZapper zapper = new MockGroupZapper(address(factory), address(pool));
        StrategyGroupRegistry.GroupInput memory value = input();
        value.factory = address(factory);
        value.router = address(router);
        value.zapper = address(zapper);

        registry.setGroup(GROUP, value);

        StrategyGroupRegistry.Group memory stored = registry.group(GROUP);
        assertEq(stored.factory, address(factory));
        assertEq(stored.router, address(router));
        assertEq(stored.zapper, address(zapper));
    }

    function test_updateChangesMetadataWithoutDuplicatingIdentity() public {
        registry.setGroup(GROUP, input());
        StrategyGroupRegistry.GroupInput memory value = input();
        value.active = false;
        value.name = "sUSDai reserve paused for new issuance";
        registry.setGroup(GROUP, value);

        StrategyGroupRegistry.Group memory stored = registry.group(GROUP);
        assertFalse(stored.active);
        assertEq(stored.name, value.name);
        assertEq(registry.groupCount(), 1);
    }

    function test_deactivateGroupWorksWhenDependencyWiringIsBroken() public {
        registry.setGroup(GROUP, input());
        pool.setYieldSource(makeAddr("broken-source"));

        registry.deactivateGroup(GROUP);

        assertFalse(registry.group(GROUP).active);
    }

    function test_deactivateGroupRejectsUnknownGroupAndNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(StrategyGroupRegistry.GroupNotFound.selector, GROUP));
        registry.deactivateGroup(GROUP);

        registry.setGroup(GROUP, input());
        address caller = makeAddr("caller");
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        registry.deactivateGroup(GROUP);
    }

    function test_rejectsIdentityRedirection() public {
        registry.setGroup(GROUP, input());
        MockGroupPool replacement = new MockGroupPool(asset, yieldSource);
        StrategyGroupRegistry.GroupInput memory value = input();
        value.reservePool = address(replacement);

        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyGroupRegistry.GroupIdentityImmutable.selector,
                GROUP,
                address(pool),
                address(replacement)
            )
        );
        registry.setGroup(GROUP, value);
    }

    function test_rejectsNonOwner() public {
        address caller = makeAddr("caller");
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        registry.setGroup(GROUP, input());
    }

    function test_rejectsUnknownGroupRead() public {
        vm.expectRevert(abi.encodeWithSelector(StrategyGroupRegistry.GroupNotFound.selector, GROUP));
        registry.group(GROUP);
    }

    function test_rejectsInvalidIdentityAndMetadata() public {
        vm.expectRevert(StrategyGroupRegistry.InvalidGroupId.selector);
        registry.setGroup(bytes32(0), input());

        StrategyGroupRegistry.GroupInput memory value = input();
        value.name = "";
        vm.expectRevert(StrategyGroupRegistry.EmptyMetadata.selector);
        registry.setGroup(GROUP, value);

        value = input();
        value.strategy = "";
        vm.expectRevert(StrategyGroupRegistry.EmptyMetadata.selector);
        registry.setGroup(GROUP, value);
    }

    function test_rejectsMissingOrUndeployedCoreContracts() public {
        StrategyGroupRegistry.GroupInput memory value = input();
        value.reservePool = address(0);
        vm.expectRevert(StrategyGroupRegistry.ZeroAddress.selector);
        registry.setGroup(GROUP, value);

        value = input();
        value.yieldSource = address(0);
        vm.expectRevert(StrategyGroupRegistry.ZeroAddress.selector);
        registry.setGroup(GROUP, value);

        value = input();
        value.reservePool = makeAddr("no-code-pool");
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyGroupRegistry.ContractNotDeployed.selector, value.reservePool
            )
        );
        registry.setGroup(GROUP, value);

        value = input();
        value.yieldSource = makeAddr("no-code-source");
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyGroupRegistry.ContractNotDeployed.selector, value.yieldSource
            )
        );
        registry.setGroup(GROUP, value);
    }

    function test_rejectsPoolYieldSourceMismatch() public {
        address other = address(new MockGroupFactory(address(0)));
        StrategyGroupRegistry.GroupInput memory value = input();
        value.yieldSource = other;
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyGroupRegistry.YieldSourceMismatch.selector, other, yieldSource
            )
        );
        registry.setGroup(GROUP, value);
    }

    function test_rejectsIncompleteMarketStack() public {
        MockGroupFactory factory = new MockGroupFactory(address(pool));
        StrategyGroupRegistry.GroupInput memory value = input();
        value.factory = address(factory);
        vm.expectRevert(StrategyGroupRegistry.InvalidMarketStack.selector);
        registry.setGroup(GROUP, value);

        value = input();
        value.zapper = address(new MockGroupZapper(address(factory), address(pool)));
        vm.expectRevert(StrategyGroupRegistry.InvalidMarketStack.selector);
        registry.setGroup(GROUP, value);
    }

    function test_rejectsMarketContractsWithoutCode() public {
        StrategyGroupRegistry.GroupInput memory value = input();
        value.factory = makeAddr("factory");
        value.router = makeAddr("router");
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyGroupRegistry.ContractNotDeployed.selector, value.factory
            )
        );
        registry.setGroup(GROUP, value);
    }

    function test_rejectsFactoryReserveMismatch() public {
        address wrong = makeAddr("wrong-reserve");
        MockGroupFactory factory = new MockGroupFactory(wrong);
        MockGroupRouter router = new MockGroupRouter(address(factory), address(pool));
        StrategyGroupRegistry.GroupInput memory value = input();
        value.factory = address(factory);
        value.router = address(router);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyGroupRegistry.FactoryReserveMismatch.selector, address(pool), wrong
            )
        );
        registry.setGroup(GROUP, value);
    }

    /// @notice One factory serves several groups: its own `reservePool()` is only its default,
    ///         and a group whose reserve it has approved is a valid stack.
    function test_acceptsASharedFactoryThatApprovesTheGroupsReserve() public {
        address defaultReserve = makeAddr("default-reserve");
        MockGroupFactory factory = new MockGroupFactory(defaultReserve);
        factory.approveReserve(address(pool));
        MockGroupRouter router = new MockGroupRouter(address(factory), defaultReserve);
        MockGroupZapper zapper = new MockGroupZapper(address(factory), defaultReserve);

        StrategyGroupRegistry.GroupInput memory value = input();
        value.factory = address(factory);
        value.router = address(router);
        value.zapper = address(zapper);
        registry.setGroup(GROUP, value);

        StrategyGroupRegistry.Group memory stored = registry.group(GROUP);
        assertEq(stored.factory, address(factory));
        assertEq(stored.router, address(router));
        assertEq(stored.zapper, address(zapper));
        assertEq(stored.reservePool, address(pool), "the group keeps its own reserve identity");
    }

    /// @notice A router or zapper answering the right factory but a third reserve is still
    ///         rejected: its fallback must be one of the two reserves in play.
    function test_rejectsASharedStackPointedAtAThirdReserve() public {
        address defaultReserve = makeAddr("default-reserve");
        address wrong = makeAddr("third-reserve");
        MockGroupFactory factory = new MockGroupFactory(defaultReserve);
        factory.approveReserve(address(pool));
        MockGroupRouter router = new MockGroupRouter(address(factory), wrong);

        StrategyGroupRegistry.GroupInput memory value = input();
        value.factory = address(factory);
        value.router = address(router);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyGroupRegistry.RouterReserveMismatch.selector, address(pool), wrong
            )
        );
        registry.setGroup(GROUP, value);
    }

    function test_rejectsRouterFactoryMismatch() public {
        MockGroupFactory factory = new MockGroupFactory(address(pool));
        address wrong = makeAddr("wrong-factory");
        MockGroupRouter router = new MockGroupRouter(wrong, address(pool));
        StrategyGroupRegistry.GroupInput memory value = input();
        value.factory = address(factory);
        value.router = address(router);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyGroupRegistry.RouterFactoryMismatch.selector, address(factory), wrong
            )
        );
        registry.setGroup(GROUP, value);
    }

    function test_rejectsRouterReserveMismatch() public {
        MockGroupFactory factory = new MockGroupFactory(address(pool));
        address wrong = makeAddr("wrong-reserve");
        MockGroupRouter router = new MockGroupRouter(address(factory), wrong);
        StrategyGroupRegistry.GroupInput memory value = input();
        value.factory = address(factory);
        value.router = address(router);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyGroupRegistry.RouterReserveMismatch.selector, address(pool), wrong
            )
        );
        registry.setGroup(GROUP, value);
    }

    function test_rejectsZapperBindings() public {
        MockGroupFactory factory = new MockGroupFactory(address(pool));
        MockGroupRouter router = new MockGroupRouter(address(factory), address(pool));
        address wrongFactory = makeAddr("wrong-factory");
        MockGroupZapper badFactory = new MockGroupZapper(wrongFactory, address(pool));
        StrategyGroupRegistry.GroupInput memory value = input();
        value.factory = address(factory);
        value.router = address(router);
        value.zapper = address(badFactory);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyGroupRegistry.ZapperFactoryMismatch.selector, address(factory), wrongFactory
            )
        );
        registry.setGroup(GROUP, value);

        address wrongReserve = makeAddr("wrong-reserve");
        MockGroupZapper badReserve = new MockGroupZapper(address(factory), wrongReserve);
        value.zapper = address(badReserve);
        vm.expectRevert(
            abi.encodeWithSelector(
                StrategyGroupRegistry.ZapperReserveMismatch.selector, address(pool), wrongReserve
            )
        );
        registry.setGroup(GROUP, value);
    }

    /// @notice The directory is fixable in place: the owner upgrades it in a single transaction
    ///         and the published group table is still readable afterwards. Nobody else can.
    function test_ownerUpgradesInOneTxAndGroupsSurvive() public {
        registry.setGroup(GROUP, input());

        address v2 = address(new StrategyGroupRegistryV2());

        address caller = makeAddr("caller");
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        StrategyGroupRegistry(address(registry)).upgradeToAndCall(v2, "");

        StrategyGroupRegistry(address(registry)).upgradeToAndCall(v2, "");

        assertEq(StrategyGroupRegistryV2(address(registry)).version(), 2, "new code is live");
        StrategyGroupRegistry.Group memory stored = registry.group(GROUP);
        assertEq(stored.reservePool, address(pool));
        assertEq(stored.asset, asset);
        assertEq(stored.yieldSource, yieldSource);
        assertEq(stored.policyId, POLICY);
        assertTrue(stored.active);
        assertEq(stored.name, "sUSDai reserve");
        assertEq(stored.strategy, "sUSDai on Arbitrum");
        assertTrue(registry.exists(GROUP));
        assertEq(registry.groupCount(), 1);
        assertEq(registry.groupIdAt(0), GROUP);
        assertEq(registry.owner(), address(this), "ownership survived");

        // The appended variable did not land on anything already there.
        StrategyGroupRegistryV2(address(registry)).setUpgradeNote("v2");
        assertEq(StrategyGroupRegistryV2(address(registry)).upgradeNote(), "v2");
        assertEq(registry.groupIdAt(0), GROUP, "and the table still resolves");
    }

    /// @notice Renouncing would take `_authorizeUpgrade` and `deactivateGroup` — the emergency
    ///         stop this contract's docs promise stays reachable — with it, in one non-two-step
    ///         call from the owner EOA. So it must not be reachable at all.
    function test_ownershipCannotBeRenounced() public {
        vm.expectRevert(StrategyGroupRegistry.OwnershipCannotBeRenounced.selector);
        registry.renounceOwnership();

        assertEq(registry.owner(), address(this), "owner unchanged");
        registry.setGroup(GROUP, input());
        registry.deactivateGroup(GROUP);
        assertFalse(registry.group(GROUP).active, "the emergency stop is still reachable");
    }
}
