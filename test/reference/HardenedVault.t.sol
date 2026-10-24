// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {ERC4626InvariantSuite} from "../../src/ERC4626InvariantSuite.sol";
import {MockAsset} from "../mocks/MockAsset.sol";
import {HardenedVault} from "../vaults/ReferenceVaults.sol";

/// @notice A donation-hardened vault passes every check, including the strict zero-share opt-in.
contract HardenedVaultTest is ERC4626InvariantSuite {
    function _deployVault() internal override returns (IERC4626) {
        return new HardenedVault(new MockAsset());
    }

    function _rejectZeroShareDeposits() internal pure override returns (bool) {
        return true;
    }
}
