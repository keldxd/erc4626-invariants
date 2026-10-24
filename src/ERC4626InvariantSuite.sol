// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {ERC4626Handler} from "./ERC4626Handler.sol";

/// @title ERC4626InvariantSuite
/// @author Kelvin Mwangi (keldxd)
/// @notice Inherit this, implement `_deployVault()`, and run `forge test`. You get stateful invariant tests
///         (thousands of random multi-user action sequences) plus stateless round-trip fuzz tests.
///
///         What is checked, in plain words:
///         1. Backing:        the vault never claims more assets than it actually holds
///         2. Solvency:       all shares together are never worth more than totalAssets()
///         3. No free value:  users can never end up with more than they put in plus the yield earned
///         4. Honest previews: previewX never promises a better deal than X actually gives
///         5. Honest limits:  any amount within maxX never reverts
///         6. Rounding:       every preview rounds in the vault's favour, never the user's
///         7. Round trips:    depositing then withdrawing (or minting then redeeming) never makes a profit
///         8. (opt-in) No zero-share deposits: a deposit of real assets never mints nothing
///
/// @dev Defaults suit a vault that keeps its assets in its own balance (like OpenZeppelin's ERC4626).
///      Override the `_...()` hooks below to adapt it to your vault.
abstract contract ERC4626InvariantSuite is Test {
    IERC4626 internal vault;
    IERC20 internal asset;
    ERC4626Handler internal handler;

    /* ------------------------------------------------------------------------------------------- */
    /*                                  HOOKS (override to configure)                              */
    /* ------------------------------------------------------------------------------------------- */

    /// @notice Deploy and return the vault under test. Its asset must work with forge-std's `deal`.
    function _deployVault() internal virtual returns (IERC4626);

    /// @notice Number of independent users. More users = more cross-user interactions.
    function _numActors() internal view virtual returns (uint256) {
        return 3;
    }

    /// @notice Asset tokens given to each user (default: 1,000,000 whole tokens).
    function _initialBalance() internal view virtual returns (uint256) {
        return 1_000_000 * 10 ** IERC20Metadata(address(asset)).decimals();
    }

    /// @notice Let users transfer assets straight into the vault (donation / inflation attempts).
    function _donationsEnabled() internal view virtual returns (bool) {
        return true;
    }

    /// @notice Simulate the vault earning yield.
    function _yieldEnabled() internal view virtual returns (bool) {
        return true;
    }

    /// @notice True if every asset the vault reports must sit in its own balance. Turn off for vaults that
    ///         deploy assets into strategies or other protocols.
    function _assetsHeldByVault() internal view virtual returns (bool) {
        return true;
    }

    /// @notice Opt in to require that no deposit of real assets ever mints zero shares. Vaults without an
    ///         explicit zero-share revert usually fail this once donations are enabled, which is exactly the
    ///         precondition for donation / inflation attacks.
    function _rejectZeroShareDeposits() internal view virtual returns (bool) {
        return false;
    }

    /// @notice Rounding slack (in asset wei) allowed on the value invariants. A compliant vault always rounds
    ///         in its own favour, so the default is zero.
    function _valueTolerance() internal view virtual returns (uint256) {
        return 0;
    }

    /// @notice Deploy your own handler subclass here if the vault needs custom yield simulation.
    function _deployHandler(ERC4626Handler.Config memory config) internal virtual returns (ERC4626Handler) {
        return new ERC4626Handler(vault, config);
    }

    /* ------------------------------------------------------------------------------------------- */
    /*                                            SETUP                                            */
    /* ------------------------------------------------------------------------------------------- */

    function setUp() public virtual {
        vault = _deployVault();
        asset = IERC20(vault.asset());

        handler = _deployHandler(
            ERC4626Handler.Config({
                numActors: _numActors(),
                initialBalance: _initialBalance(),
                donationsEnabled: _donationsEnabled(),
                yieldEnabled: _yieldEnabled()
            })
        );

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = ERC4626Handler.deposit.selector;
        selectors[1] = ERC4626Handler.mint.selector;
        selectors[2] = ERC4626Handler.withdraw.selector;
        selectors[3] = ERC4626Handler.redeem.selector;
        selectors[4] = ERC4626Handler.transferShares.selector;
        selectors[5] = ERC4626Handler.donate.selector;
        selectors[6] = ERC4626Handler.simulateYield.selector;
        selectors[7] = ERC4626Handler.warp.selector;
        selectors[8] = ERC4626Handler.probeRounding.selector;
        selectors[9] = ERC4626Handler.deposit.selector; // weight deposits x2 so vaults fill up
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /* ------------------------------------------------------------------------------------------- */
    /*                                 STATEFUL INVARIANTS (random sequences)                      */
    /* ------------------------------------------------------------------------------------------- */

    /// @notice 1. The vault never reports more assets than it actually holds.
    function invariant_backing() public view {
        if (!_assetsHeldByVault()) return;
        assertLe(vault.totalAssets(), asset.balanceOf(address(vault)), "totalAssets() exceeds actual asset balance");
    }

    /// @notice 2. All shares together are never worth more than the vault's total assets.
    function invariant_solvency() public view {
        assertLe(
            vault.convertToAssets(vault.totalSupply()),
            vault.totalAssets() + _valueTolerance(),
            "outstanding shares are worth more than totalAssets()"
        );
    }

    /// @notice 3. Users can never end up with more than they started with plus the yield the vault earned.
    function invariant_noValueCreated() public view {
        assertLe(
            handler.totalUserValue(),
            handler.valueCeiling() + _valueTolerance(),
            "users hold more value than was ever put in plus yield"
        );
    }

    /// @notice 4. Previews never promise a better deal than the real call (EIP-4626).
    function invariant_previewsAreHonest() public view {
        assertFalse(handler.previewDepositViolated(), "deposit minted fewer shares than previewDeposit");
        assertFalse(handler.previewMintViolated(), "mint charged more assets than previewMint");
        assertFalse(handler.previewWithdrawViolated(), "withdraw burned more shares than previewWithdraw");
        assertFalse(handler.previewRedeemViolated(), "redeem paid fewer assets than previewRedeem");
    }

    /// @notice 5. Any amount within the reported max never reverts (EIP-4626).
    function invariant_limitsAreHonest() public view {
        assertFalse(handler.maxDepositViolated(), "deposit within maxDeposit reverted");
        assertFalse(handler.maxMintViolated(), "mint within maxMint reverted");
        assertFalse(handler.maxWithdrawViolated(), "withdraw within maxWithdraw reverted");
        assertFalse(handler.maxRedeemViolated(), "redeem within maxRedeem reverted");
    }

    /// @notice 6. Every preview rounds in the vault's favour (EIP-4626 rounding direction).
    function invariant_roundingFavoursVault() public view {
        assertFalse(handler.roundingViolated(), handler.roundingViolation());
    }

    /// @notice 8. (opt-in) No deposit of real assets ever mints zero shares.
    function invariant_noZeroShareDeposits() public view {
        if (!_rejectZeroShareDeposits()) return;
        assertEq(handler.zeroShareDeposits(), 0, "a deposit of real assets minted zero shares");
    }

    /// @notice Prints how many actions really succeeded in the last sequence, so a passing run can be checked
    ///         for real coverage rather than silently doing nothing.
    function afterInvariant() external view {
        console2.log("coverage (last run) deposits/mints/withdrawals/redemptions:");
        console2.log(handler.deposits(), handler.mints(), handler.withdrawals(), handler.redemptions());
        console2.log("transfers/donations/yields:");
        console2.log(handler.transfers(), handler.donations(), handler.yields());
    }

    /* ------------------------------------------------------------------------------------------- */
    /*                                 STATELESS ROUND-TRIP FUZZ TESTS                             */
    /* ------------------------------------------------------------------------------------------- */

    /// @dev Puts the vault into a random non-trivial state (existing depositor, yield, donation) so the
    ///      share price is not 1:1 when the round trip runs.
    function _randomPriorState(uint256 seedDeposit, uint256 seedYield) internal {
        address whale = makeAddr("roundtrip-whale");
        seedDeposit = bound(seedDeposit, 0, _initialBalance());
        if (seedDeposit > 0 && vault.maxDeposit(whale) >= seedDeposit) {
            deal(address(asset), whale, seedDeposit);
            vm.startPrank(whale);
            SafeERC20.forceApprove(asset, address(vault), seedDeposit);
            try vault.deposit(seedDeposit, whale) {} catch {}
            vm.stopPrank();
        }
        if (_yieldEnabled() && _assetsHeldByVault()) {
            uint256 held = asset.balanceOf(address(vault));
            seedYield = bound(seedYield, 0, held / 2 + 1);
            deal(address(asset), address(vault), held + seedYield);
        }
    }

    /// @notice 7a. Depositing then redeeming everything never returns more than was deposited.
    function testFuzz_depositRedeemRoundTrip(uint256 seedDeposit, uint256 seedYield, uint256 assets) public {
        _randomPriorState(seedDeposit, seedYield);
        address user = makeAddr("roundtrip-user");
        assets = bound(assets, 1, _initialBalance());
        if (vault.maxDeposit(user) < assets || vault.previewDeposit(assets) == 0) return;

        deal(address(asset), user, assets);
        vm.startPrank(user);
        SafeERC20.forceApprove(asset, address(vault), assets);
        // forge-lint: disable-next-line(unused-return) -- balances are measured directly, not trusted from returns
        vault.deposit(assets, user);
        uint256 shares = vault.balanceOf(user);
        // forge-lint: disable-next-line(unused-return) -- balances are measured directly, not trusted from returns
        if (shares > 0) vault.redeem(shares, user, user);
        vm.stopPrank();

        assertLe(asset.balanceOf(user), assets, "deposit -> redeem round trip made a profit");
    }

    /// @notice 7b. Minting shares then withdrawing their full value never returns more than was paid.
    function testFuzz_mintWithdrawRoundTrip(uint256 seedDeposit, uint256 seedYield, uint256 shares) public {
        _randomPriorState(seedDeposit, seedYield);
        address user = makeAddr("roundtrip-user");
        uint256 maxShares = vault.previewDeposit(_initialBalance());
        if (maxShares == 0) return;
        shares = bound(shares, 1, maxShares);
        uint256 cost = vault.previewMint(shares);
        if (cost == 0 || cost > _initialBalance() || vault.maxMint(user) < shares) return;

        deal(address(asset), user, cost);
        vm.startPrank(user);
        SafeERC20.forceApprove(asset, address(vault), cost);
        // forge-lint: disable-next-line(unused-return) -- balances are measured directly, not trusted from returns
        vault.mint(shares, user);
        uint256 out = vault.maxWithdraw(user);
        // forge-lint: disable-next-line(unused-return) -- balances are measured directly, not trusted from returns
        if (out > 0) vault.withdraw(out, user, user);
        vm.stopPrank();

        assertLe(asset.balanceOf(user), cost, "mint -> withdraw round trip made a profit");
    }
}
