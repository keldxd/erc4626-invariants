// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice Unmodified OpenZeppelin ERC4626. The baseline every check must pass on.
contract OpenZeppelinVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("OZ Vault", "ozV") ERC4626(asset_) {}
}

/// @notice OpenZeppelin ERC4626 hardened against donation attacks: 6 decimals of virtual shares, and
///         deposits that would mint zero shares revert. Passes the strict opt-in zero-share check too.
contract HardenedVault is ERC4626 {
    error ZeroShares();

    constructor(IERC20 asset_) ERC20("Hardened Vault", "hV") ERC4626(asset_) {}

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        if (previewDeposit(assets) == 0) revert ZeroShares();
        shares = super.deposit(assets, receiver);
    }
}
