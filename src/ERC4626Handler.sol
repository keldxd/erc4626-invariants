// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @title ERC4626Handler
/// @author Kelvin Mwangi (keldxd)
/// @notice Drives any ERC4626 vault with several independent users and records every broken promise.
///
///         The fuzzer calls these functions in random order with random amounts. Each action checks the
///         vault against the ERC4626 standard (EIP-4626) using real balance changes, never the vault's own
///         return values, so a vault cannot hide a bug by lying in what it returns:
///
///         - previewDeposit / previewRedeem must not promise MORE than the call actually delivers
///         - previewMint / previewWithdraw must not promise to charge LESS than the call actually takes
///         - an amount within maxDeposit / maxMint / maxWithdraw / maxRedeem must not revert
///
///         The suite then turns these records into invariants (see ERC4626InvariantSuite).
contract ERC4626Handler is Test {
    struct Config {
        uint256 numActors; // independent users
        uint256 initialBalance; // asset tokens given to each user at the start
        bool donationsEnabled; // users may transfer assets straight to the vault (donation / inflation attempts)
        bool yieldEnabled; // simulate the vault earning yield
    }

    // forge-lint: disable-next-line(screaming-snake-case-immutable) -- readable public getter `vault()`
    IERC4626 public immutable vault;
    // forge-lint: disable-next-line(screaming-snake-case-immutable) -- readable public getter `asset()`
    IERC20 public immutable asset;
    Config public config;
    address[] public actors;

    /// @notice total yield injected into the vault (part of the value users are allowed to own)
    uint256 public totalYield;

    // --- broken-promise records (any `true` / nonzero value is a bug) ---
    bool public previewDepositViolated;
    bool public previewMintViolated;
    bool public previewWithdrawViolated;
    bool public previewRedeemViolated;
    bool public maxDepositViolated;
    bool public maxMintViolated;
    bool public maxWithdrawViolated;
    bool public maxRedeemViolated;
    uint256 public zeroShareDeposits; // deposits of >0 assets that minted 0 shares
    bool public roundingViolated; // a preview rounded in the user's favour
    string public roundingViolation; // which rule broke, for the failure message

    // --- coverage counters (successful calls), so a "green" run can be shown to be non-vacuous ---
    uint256 public deposits;
    uint256 public mints;
    uint256 public withdrawals;
    uint256 public redemptions;
    uint256 public transfers;
    uint256 public donations;
    uint256 public yields;

    constructor(IERC4626 _vault, Config memory _config) {
        vault = _vault;
        asset = IERC20(_vault.asset());
        config = _config;

        // forge-lint: disable-start(calls-loop) -- one-time test setup for a handful of users
        for (uint256 i = 0; i < _config.numActors; i++) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(actor);
            deal(address(asset), actor, _config.initialBalance);
            vm.prank(actor);
            // forceApprove also supports tokens like USDT whose approve returns nothing
            SafeERC20.forceApprove(asset, address(_vault), type(uint256).max);
        }
        // forge-lint: disable-end(calls-loop)
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /* ------------------------------------------------------------------------------------------- */
    /*                                       FUZZED ACTIONS                                        */
    /* ------------------------------------------------------------------------------------------- */

    function deposit(uint256 actorSeed, uint256 assets) external {
        address actor = _actor(actorSeed);
        uint256 cap = Math.min(asset.balanceOf(actor), vault.maxDeposit(actor));
        if (cap == 0) return;
        assets = bound(assets, 1, cap);

        uint256 preview = vault.previewDeposit(assets);
        uint256 sharesBefore = vault.balanceOf(actor);

        vm.prank(actor);
        try vault.deposit(assets, actor) {
            uint256 minted = vault.balanceOf(actor) - sharesBefore;
            if (minted < preview) previewDepositViolated = true;
            if (minted == 0) zeroShareDeposits++;
            deposits++;
        } catch {
            // a vault may refuse a deposit that would mint nothing; anything else within maxDeposit is a bug
            if (preview > 0) maxDepositViolated = true;
        }
    }

    function mint(uint256 actorSeed, uint256 shares) external {
        address actor = _actor(actorSeed);
        uint256 wallet = asset.balanceOf(actor);
        uint256 cap = Math.min(vault.maxMint(actor), vault.previewDeposit(wallet));
        if (cap == 0) return;
        shares = bound(shares, 1, cap);

        uint256 preview = vault.previewMint(shares);
        if (preview > wallet) return;
        uint256 assetsBefore = asset.balanceOf(actor);

        vm.prank(actor);
        try vault.mint(shares, actor) {
            uint256 charged = assetsBefore - asset.balanceOf(actor);
            if (charged > preview) previewMintViolated = true;
            mints++;
        } catch {
            maxMintViolated = true;
        }
    }

    function withdraw(uint256 actorSeed, uint256 assets) external {
        address actor = _actor(actorSeed);
        uint256 cap = vault.maxWithdraw(actor);
        if (cap == 0) return;
        assets = bound(assets, 1, cap);

        uint256 preview = vault.previewWithdraw(assets);
        uint256 sharesBefore = vault.balanceOf(actor);

        vm.prank(actor);
        try vault.withdraw(assets, actor, actor) {
            uint256 burned = sharesBefore - vault.balanceOf(actor);
            if (burned > preview) previewWithdrawViolated = true;
            withdrawals++;
        } catch {
            maxWithdrawViolated = true;
        }
    }

    function redeem(uint256 actorSeed, uint256 shares) external {
        address actor = _actor(actorSeed);
        uint256 cap = vault.maxRedeem(actor);
        if (cap == 0) return;
        shares = bound(shares, 1, cap);

        uint256 preview = vault.previewRedeem(shares);
        uint256 assetsBefore = asset.balanceOf(actor);

        vm.prank(actor);
        try vault.redeem(shares, actor, actor) {
            uint256 received = asset.balanceOf(actor) - assetsBefore;
            if (received < preview) previewRedeemViolated = true;
            redemptions++;
        } catch {
            maxRedeemViolated = true;
        }
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 shares) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = vault.balanceOf(from);
        if (bal == 0 || from == to) return;
        shares = bound(shares, 1, bal);

        vm.prank(from);
        try vault.transfer(to, shares) {
            transfers++;
        } catch {}
    }

    /// @notice A user sends assets straight to the vault without minting shares (donation / inflation attempt).
    function donate(uint256 actorSeed, uint256 assets) external {
        if (!config.donationsEnabled) return;
        address actor = _actor(actorSeed);
        uint256 bal = asset.balanceOf(actor);
        if (bal == 0) return;
        assets = bound(assets, 1, bal);

        vm.prank(actor);
        try asset.transfer(address(vault), assets) {
            donations++;
        } catch {}
    }

    /// @notice The vault earns yield (up to ~1% of its assets per call). Override for vaults that keep
    ///         their assets somewhere other than their own balance.
    function simulateYield(uint256 amount) external virtual {
        if (!config.yieldEnabled) return;
        uint256 held = asset.balanceOf(address(vault));
        if (held == 0) return;
        amount = bound(amount, 1, Math.max(1, held / 100));
        deal(address(asset), address(vault), held + amount);
        totalYield += amount;
        yields++;
    }

    /// @notice Checks EIP-4626 rounding direction at random amounts in the current state. Every preview must
    ///         round in the vault's favour relative to the fee-free, round-down conversion functions. This
    ///         holds for any compliant vault, with or without fees, and catches leaks too small (1 wei per call)
    ///         for the value invariants to see within one run.
    function probeRounding(uint256 assets, uint256 shares) external {
        assets = bound(assets, 1, asset.balanceOf(address(vault)) + config.initialBalance);
        shares = bound(shares, 1, vault.totalSupply() + config.initialBalance);

        if (vault.previewDeposit(assets) > vault.convertToShares(assets)) {
            _flagRounding("previewDeposit rounds up: gives more shares than convertToShares");
        }
        if (vault.previewRedeem(shares) > vault.convertToAssets(shares)) {
            _flagRounding("previewRedeem rounds up: pays more assets than convertToAssets");
        }
        if (vault.previewMint(shares) < vault.convertToAssets(shares)) {
            _flagRounding("previewMint rounds down: charges fewer assets than convertToAssets");
        }
        if (vault.previewWithdraw(assets) < vault.convertToShares(assets)) {
            _flagRounding("previewWithdraw rounds down: burns fewer shares than convertToShares");
        }
    }

    function _flagRounding(string memory rule) internal {
        if (!roundingViolated) {
            roundingViolated = true;
            roundingViolation = rule;
        }
    }

    function warp(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1, 7 days));
    }

    /* ------------------------------------------------------------------------------------------- */
    /*                                   VIEWS FOR THE INVARIANTS                                  */
    /* ------------------------------------------------------------------------------------------- */

    /// @notice Everything all users could walk away with: wallet balances plus the value of their shares.
    function totalUserValue() external view returns (uint256 total) {
        // forge-lint: disable-start(calls-loop) -- test-only view over a handful of users
        for (uint256 i = 0; i < actors.length; i++) {
            total += asset.balanceOf(actors[i]);
            total += vault.convertToAssets(vault.balanceOf(actors[i]));
        }
        // forge-lint: disable-end(calls-loop)
    }

    /// @notice The most users are entitled to: what they started with plus all yield the vault earned.
    function valueCeiling() external view returns (uint256) {
        return config.initialBalance * actors.length + totalYield;
    }
}
