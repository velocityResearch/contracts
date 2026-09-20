// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "oz-upgradeable/access/Ownable2StepUpgradeable.sol";

interface IStrategyGroupPool {
    function asset() external view returns (address);
    function yieldSource() external view returns (address);
}

interface IStrategyGroupFactory {
    function reservePool() external view returns (address);
    function approvedReservePool(address reservePool) external view returns (bool);
}

interface IStrategyGroupRouter {
    function factory() external view returns (address);
    function reservePool() external view returns (address);
}

interface IStrategyGroupZapper {
    function factory() external view returns (address);
    function reservePool() external view returns (address);
}

/// @title StrategyGroupRegistry
/// @notice Owner-managed discovery directory for reserve groups. Dynamic accounting and brand
///         membership remain authoritative in each reserve pool; this contract only publishes
///         validated bindings and stable group metadata for applications and indexers.
///
///         **What keeps the emergency stop reachable.** The registry used to be non-upgradeable,
///         and the reason given was that fixed code cannot have its emergency deactivation path
///         taken away. That is no longer what protects the path, because the owner can now
///         replace this implementation behind its proxy. What still protects it is the shape of
///         `deactivateGroup` itself: it writes one bool and makes no call into any reserve pool,
///         factory, router or zapper, so a group whose live wiring is broken — a pool that
///         reverts, a yield source that has moved — can always still be pulled out of
///         application discovery. `setGroup` is the only function that touches a dependency, and
///         it is only ever the path back IN, which is why reactivation goes through it rather
///         than through the emergency stop.
///
///         The registry is upgradeable because it holds the group table: group ids are quoted by
///         indexers and front ends, so the directory has to be fixable in place rather than
///         redeployed at a new address. The cost of that is one more thing the owner can change;
///         upgrades are authorized by the owner alone (`_authorizeUpgrade`), the same key that
///         already controls `setGroup` and `deactivateGroup`.
contract StrategyGroupRegistry is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    struct GroupInput {
        address reservePool;
        address yieldSource;
        address factory;
        address router;
        address zapper;
        bytes32 policyId;
        bool active;
        string name;
        string strategy;
    }

    struct Group {
        address reservePool;
        address asset;
        address yieldSource;
        address factory;
        address router;
        address zapper;
        bytes32 policyId;
        bool active;
        string name;
        string strategy;
    }

    // ─── Storage ─────────────────────────────────────────────────────────
    //
    // This contract is upgraded in place, so the declaration order below is part of its
    // on-chain layout: append only, never reorder, never remove.

    /// @dev Slot 0 of this contract's own layout: the published record for each group id.
    mapping(bytes32 groupId => Group) private _groups;

    /// @dev Slot 1: registration flag, read before every group access. Separate from `_groups`
    ///      because a registered group may legitimately be all-zero-valued in some field.
    mapping(bytes32 groupId => bool) public exists;

    /// @dev Slot 2: insertion-ordered group ids, for the enumeration API. Entries are never
    ///      removed — a retired group is deactivated, not deleted, so indexers that cached an
    ///      index keep resolving it.
    bytes32[] private _groupIds;

    event GroupConfigured(
        bytes32 indexed groupId,
        address indexed reservePool,
        address indexed yieldSource,
        address factory,
        address router,
        address zapper,
        bytes32 policyId,
        bool active,
        string name,
        string strategy
    );
    event GroupDeactivated(bytes32 indexed groupId);

    error ZeroAddress();
    error InvalidGroupId();
    error EmptyMetadata();
    error ContractNotDeployed(address target);
    error YieldSourceMismatch(address configured, address poolYieldSource);
    error InvalidMarketStack();
    error FactoryReserveMismatch(address configured, address factoryReserve);
    error RouterFactoryMismatch(address configured, address routerFactory);
    error RouterReserveMismatch(address configured, address routerReserve);
    error ZapperFactoryMismatch(address configured, address zapperFactory);
    error ZapperReserveMismatch(address configured, address zapperReserve);
    error GroupNotFound(bytes32 groupId);
    error GroupIdentityImmutable(bytes32 groupId, address currentReserve, address proposedReserve);
    error OwnershipCannotBeRenounced();

    constructor() {
        _disableInitializers();
    }

    /// @param owner_ Holds both group administration and the upgrade authorization.
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __Ownable2Step_init();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Always reverts. The owner key is both the upgrade authority
    ///         (`_authorizeUpgrade`) and the only caller of `deactivateGroup`, the emergency
    ///         stop this contract's docs above promise stays reachable. Renouncing is not
    ///         two-step like `transferOwnership`, so one mistaken call from the owner EOA
    ///         would remove both permanently.
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    /// @notice Add or update a group. Once a group id has been assigned to a reserve pool, that
    ///         identity cannot be redirected to another pool; deactivate it and add a new id.
    function setGroup(bytes32 groupId, GroupInput calldata input) external onlyOwner {
        if (groupId == bytes32(0)) revert InvalidGroupId();
        if (input.reservePool == address(0) || input.yieldSource == address(0)) {
            revert ZeroAddress();
        }
        if (bytes(input.name).length == 0 || bytes(input.strategy).length == 0) {
            revert EmptyMetadata();
        }
        _requireCode(input.reservePool);
        _requireCode(input.yieldSource);

        if (exists[groupId] && _groups[groupId].reservePool != input.reservePool) {
            revert GroupIdentityImmutable(groupId, _groups[groupId].reservePool, input.reservePool);
        }

        address asset = IStrategyGroupPool(input.reservePool).asset();
        if (asset == address(0)) revert ZeroAddress();
        address poolYieldSource = IStrategyGroupPool(input.reservePool).yieldSource();
        if (poolYieldSource != input.yieldSource) {
            revert YieldSourceMismatch(input.yieldSource, poolYieldSource);
        }

        bool hasFactory = input.factory != address(0);
        bool hasRouter = input.router != address(0);
        if (hasFactory != hasRouter || (!hasFactory && input.zapper != address(0))) {
            revert InvalidMarketStack();
        }
        if (hasFactory) _validateMarketStack(input);

        if (!exists[groupId]) {
            exists[groupId] = true;
            _groupIds.push(groupId);
        }
        _groups[groupId] = Group({
            reservePool: input.reservePool,
            asset: asset,
            yieldSource: input.yieldSource,
            factory: input.factory,
            router: input.router,
            zapper: input.zapper,
            policyId: input.policyId,
            active: input.active,
            name: input.name,
            strategy: input.strategy
        });

        emit GroupConfigured(
            groupId,
            input.reservePool,
            input.yieldSource,
            input.factory,
            input.router,
            input.zapper,
            input.policyId,
            input.active,
            input.name,
            input.strategy
        );
    }

    /// @notice Emergency discovery stop that does not call any group dependency. Reactivation
    ///         deliberately goes through `setGroup`, which validates the complete live wiring.
    function deactivateGroup(bytes32 groupId) external onlyOwner {
        if (!exists[groupId]) revert GroupNotFound(groupId);
        _groups[groupId].active = false;
        emit GroupDeactivated(groupId);
    }

    function group(bytes32 groupId) external view returns (Group memory result) {
        if (!exists[groupId]) revert GroupNotFound(groupId);
        return _groups[groupId];
    }

    function groupCount() external view returns (uint256) {
        return _groupIds.length;
    }

    function groupIdAt(uint256 index) external view returns (bytes32) {
        return _groupIds[index];
    }

    /// @dev A market stack serves a group when the factory registers brands in that group's
    ///      reserve, and the router and zapper answer to that factory.
    ///
    ///      **The factory's own `reservePool()` is its default, not its only one.** One
    ///      factory serves several reserve groups — see `AssetMarketFactory` — so a stack
    ///      qualifies either by defaulting to this reserve or by approving it. The router and
    ///      the zapper are checked against the factory rather than against the reserve for
    ///      the same reason: they resolve a market's reserve from the factory's record, and
    ///      their own `reservePool()` is only the fallback for markets predating groups.
    function _validateMarketStack(GroupInput calldata input) private view {
        _requireCode(input.factory);
        _requireCode(input.router);
        if (input.zapper != address(0)) _requireCode(input.zapper);

        IStrategyGroupFactory factory = IStrategyGroupFactory(input.factory);
        address factoryReserve = factory.reservePool();
        if (factoryReserve != input.reservePool && !factory.approvedReservePool(input.reservePool))
        {
            revert FactoryReserveMismatch(input.reservePool, factoryReserve);
        }
        address routerFactory = IStrategyGroupRouter(input.router).factory();
        if (routerFactory != input.factory) {
            revert RouterFactoryMismatch(input.factory, routerFactory);
        }
        address routerReserve = IStrategyGroupRouter(input.router).reservePool();
        if (routerReserve != input.reservePool && routerReserve != factoryReserve) {
            revert RouterReserveMismatch(input.reservePool, routerReserve);
        }
        if (input.zapper != address(0)) {
            address zapperFactory = IStrategyGroupZapper(input.zapper).factory();
            if (zapperFactory != input.factory) {
                revert ZapperFactoryMismatch(input.factory, zapperFactory);
            }
            address zapperReserve = IStrategyGroupZapper(input.zapper).reservePool();
            if (zapperReserve != input.reservePool && zapperReserve != factoryReserve) {
                revert ZapperReserveMismatch(input.reservePool, zapperReserve);
            }
        }
    }

    function _requireCode(address target) private view {
        if (target.code.length == 0) revert ContractNotDeployed(target);
    }
}
