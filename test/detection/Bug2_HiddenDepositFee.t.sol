// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {ERC4626InvariantSuite} from "../../src/ERC4626InvariantSuite.sol";
import {MockAsset} from "../mocks/MockAsset.sol";
import {HiddenDepositFeeVault} from "../vaults/BuggyVaults.sol";

/// @notice Seeded bug: see HiddenDepositFeeVault in test/vaults/BuggyVaults.sol. The suite is expected to FAIL here.
contract Bug2_HiddenDepositFee is ERC4626InvariantSuite {
    function _deployVault() internal override returns (IERC4626) {
        return new HiddenDepositFeeVault(new MockAsset());
    }
}
