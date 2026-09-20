// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SharedReservePool} from "./SharedReservePool.sol";
import {BrandPsm} from "./BrandPsm.sol";

/// @title BrandPsmFactory
/// @notice Deploys and indexes one `BrandPsm` per (reserve, brand) pair.
///
///         **Permissionless, ownerless and stateless beyond the index.** A `BrandPsm` grants no
///         authority — it is a view onto `SharedReservePool` functions anybody may already call
///         — so gating its deployment would protect nothing while making the canonical window
///         for a brand depend on somebody remembering to open it. `registerBrand` on the
///         reserve is permissionless for the same reason; this matches it.
///
///         **Why a factory at all, for a contract with no privileges.** Two things an
///         aggregator needs and a bare `new` does not give: an event to index, and an address
///         it can compute before the contract exists. Deployment is `CREATE2` salted with the
///         pair, so a manifest can record the window for a brand that has not been opened yet,
///         and `psmOf` answers the same question on chain without an archive node.
contract BrandPsmFactory {
    /// @notice The canonical window for a (reserve, brand) pair, or zero if never opened.
    mapping(address reserve => mapping(address brand => address psm)) public psmOf;

    /// @notice Every window this factory has opened, in creation order.
    address[] public allPsms;

    event PsmDeployed(address indexed reserve, address indexed brand, address psm);

    error AlreadyDeployed(address psm);

    /// @notice Open the window for `brand` on `reserve`, reverting if it is already open.
    /// @dev Reverts `UnknownBrand` from `BrandPsm`'s constructor for a brand this reserve does
    ///      not hold, which is what keeps the index from filling with windows onto nothing.
    function deploy(SharedReservePool reserve, address brand) external returns (address psm) {
        address existing = psmOf[address(reserve)][brand];
        if (existing != address(0)) revert AlreadyDeployed(existing);

        psm = address(new BrandPsm{salt: _salt(address(reserve), brand)}(reserve, brand));

        psmOf[address(reserve)][brand] = psm;
        allPsms.push(psm);

        emit PsmDeployed(address(reserve), brand, psm);
    }

    /// @notice Where `deploy(reserve, brand)` will put the window, callable before it exists.
    function predict(SharedReservePool reserve, address brand) external view returns (address) {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(BrandPsm).creationCode, abi.encode(reserve, brand)));
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            _salt(address(reserve), brand),
                            initCodeHash
                        )
                    )
                )
            )
        );
    }

    function psmCount() external view returns (uint256) {
        return allPsms.length;
    }

    function _salt(address reserve, address brand) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(reserve, brand));
    }
}
