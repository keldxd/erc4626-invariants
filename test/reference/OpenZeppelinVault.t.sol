// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {ERC4626InvariantSuite} from "../../src/ERC4626InvariantSuite.sol";
import {MockAsset} from "../mocks/MockAsset.sol";
import {OpenZeppelinVault} from "../vaults/ReferenceVaults.sol";

/// @notice Baseline: an unmodified OpenZeppelin ERC4626 must pass every default check.
contract OpenZeppelinVaultTest is ERC4626InvariantSuite {
    function _deployVault() internal override returns (IERC4626) {
        return new OpenZeppelinVault(new MockAsset());
    }
}
