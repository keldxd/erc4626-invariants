// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/// Six vaults, each OpenZeppelin's ERC4626 with ONE realistic bug seeded in.
/// They exist to prove the suite catches each bug class. DO NOT USE.

/// @notice BUG 1: redeem rounds in the USER's favour (up instead of down). Each redeem can leak 1 wei,
///         which repeated at scale drains other depositors.
contract RoundsUpOnRedeemVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Bug1", "B1") ERC4626(asset_) {}

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }
}

/// @notice BUG 2: a hidden 1% deposit fee. deposit mints fewer shares than previewDeposit promised,
///         so integrators that trust the preview (routers, aggregators) silently lose 1%.
contract HiddenDepositFeeVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Bug2", "B2") ERC4626(asset_) {}

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        uint256 shares = previewDeposit(assets);
        uint256 fee = shares / 100; // not reflected in previewDeposit
        _deposit(_msgSender(), receiver, assets, shares - fee);
        return shares - fee;
    }
}

/// @notice BUG 3: a hidden 1% withdrawal fee. withdraw burns more shares than previewWithdraw said, and
///         withdrawing the advertised maxWithdraw reverts because the user doesn't own enough shares.
contract HiddenWithdrawFeeVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Bug3", "B3") ERC4626(asset_) {}

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        uint256 shares = previewWithdraw(assets);
        uint256 fee = shares / 100; // not reflected in previewWithdraw
        _withdraw(_msgSender(), receiver, owner, assets, shares + fee);
        return shares + fee;
    }
}

/// @notice BUG 4: maxWithdraw reports the vault's whole liquidity instead of what this owner can take.
///         Integrators that size withdrawals from maxWithdraw get unexpected reverts.
contract WrongMaxWithdrawVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Bug4", "B4") ERC4626(asset_) {}

    function maxWithdraw(address) public view override returns (uint256) {
        return totalAssets();
    }

    /// keep withdraw's own guard on the real balance so the lie only lives in maxWithdraw
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        uint256 shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
        return shares;
    }
}

/// @notice BUG 5: naive share math with no virtual shares and no zero-share check (the classic
///         donation / inflation pattern behind the Hundred Finance and Sonne Finance exploits).
///         After a donation, honest deposits can mint zero shares.
contract NoInflationProtectionVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Bug5", "B5") ERC4626(asset_) {}

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : Math.mulDiv(assets, supply, totalAssets(), rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : Math.mulDiv(shares, totalAssets(), supply, rounding);
    }
}

/// @notice BUG 6: totalAssets counts 1% "pending rewards" the vault does not actually hold, overstating
///         every share. The last users out cannot be paid.
contract OverstatedAssetsVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Bug6", "B6") ERC4626(asset_) {}

    function totalAssets() public view override returns (uint256) {
        uint256 held = IERC20(asset()).balanceOf(address(this));
        return held + held / 100;
    }
}
