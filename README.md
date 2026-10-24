# erc4626-invariants

[![CI](https://github.com/keldxd/erc4626-invariants/actions/workflows/test.yml/badge.svg)](https://github.com/keldxd/erc4626-invariants/actions/workflows/test.yml)

A drop-in [Foundry](https://getfoundry.sh) test suite that stress-tests any ERC4626 vault. Write about ten
lines of setup and it throws thousands of random multi-user action sequences at your vault, checking that it
stays solvent, never creates value from nothing, and that its preview, max and rounding behaviour match
the [EIP-4626](https://eips.ethereum.org/EIPS/eip-4626) standard.

Built by [Kelvin Mwangi](https://github.com/keldxd), smart contract security researcher.

## Proof it works

Six vaults, each [OpenZeppelin's ERC4626](https://docs.openzeppelin.com/contracts/5.x/erc4626) with one
realistic bug seeded in. The suite catches every one, and CI re-checks this on every push:

| Seeded bug | What's wrong | Caught by |
|---|---|---|
| `RoundsUpOnRedeem` | redeem rounds in the user's favour, leaking 1 wei per call | rounding direction |
| `HiddenDepositFee` | deposit takes a 1% fee that previewDeposit hides | honest previews |
| `HiddenWithdrawFee` | withdraw takes a 1% fee that previewWithdraw hides | honest previews, honest limits, round trip |
| `WrongMaxWithdraw` | maxWithdraw reports vault liquidity, not what the owner can take | honest limits, round trip |
| `NoInflationProtection` | naive share math: donations make honest deposits mint 0 shares (the Hundred / Sonne Finance pattern) | zero-share deposits, round trips |
| `OverstatedAssets` | totalAssets counts 1% "pending rewards" the vault doesn't hold | backing, no value created, honest limits, round trips |

The same suite passes clean on an unmodified OpenZeppelin vault and on a donation-hardened vault, at zero
rounding tolerance, so it doesn't cry wolf. Regenerate the table yourself with
`python3 scripts/detection_matrix.py`.

## Quick start

**1. Install** into your Foundry project:

```bash
forge install keldxd/erc4626-invariants
forge install OpenZeppelin/openzeppelin-contracts   # skip if you already have it
```

Add to `remappings.txt`:

```
erc4626-invariants/=lib/erc4626-invariants/src/
openzeppelin-contracts/=lib/openzeppelin-contracts/
```

Add to `foundry.toml` (the handler expects reverts to be recorded, not fatal):

```toml
[invariant]
runs = 256
depth = 100
fail_on_revert = false
```

**2. Write one test file**, for example `test/MyVault.invariants.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {ERC4626InvariantSuite} from "erc4626-invariants/ERC4626InvariantSuite.sol";
import {MyVault} from "../src/MyVault.sol";
import {MyToken} from "../src/MyToken.sol";

contract MyVaultInvariants is ERC4626InvariantSuite {
    function _deployVault() internal override returns (IERC4626) {
        return new MyVault(new MyToken());
    }
}
```

**3. Run it:**

```bash
forge test --match-contract MyVaultInvariants -vv
```

## What it checks

| # | Check | Plain-English meaning |
|---|---|---|
| 1 | `invariant_backing` | The vault never reports more assets than it actually holds |
| 2 | `invariant_solvency` | All shares together are never worth more than `totalAssets()` |
| 3 | `invariant_noValueCreated` | Users can never end up with more than they put in plus the yield the vault earned |
| 4 | `invariant_previewsAreHonest` | `previewDeposit/Mint/Withdraw/Redeem` never promise a better deal than the real call |
| 5 | `invariant_limitsAreHonest` | Any amount within `maxDeposit/Mint/Withdraw/Redeem` never reverts |
| 6 | `invariant_roundingFavoursVault` | Every preview rounds in the vault's favour, never the user's |
| 7 | `testFuzz_*RoundTrip` | Depositing then redeeming (or minting then withdrawing) never makes a profit, from random prior states |
| 8 | `invariant_noZeroShareDeposits` | (opt-in) A deposit of real assets never mints zero shares |

Previews are checked against real balance changes, never the vault's return values, so a vault can't hide
a bug by returning the right number while doing the wrong thing.

The random actions are: deposit, mint, withdraw, redeem, share transfers between users, direct donations to
the vault, simulated yield, time warps, and rounding probes, spread across three independent users.

## Configuration

Override any of these hooks in your test contract:

| Hook | Default | Change it when |
|---|---|---|
| `_numActors()` | 3 | you want more cross-user interaction |
| `_initialBalance()` | 1,000,000 whole tokens per user | your asset has unusual supply or decimals |
| `_donationsEnabled()` | true | direct transfers to your vault are impossible by design |
| `_yieldEnabled()` | true | your vault never accrues yield |
| `_assetsHeldByVault()` | true | your vault deploys assets into strategies or other protocols |
| `_rejectZeroShareDeposits()` | false | you want to require that deposits never mint zero shares |
| `_valueTolerance()` | 0 wei | your vault has documented rounding slack |
| `_deployHandler(config)` | default handler | your vault needs custom yield simulation (subclass `ERC4626Handler` and override `simulateYield`) |

After each run, the suite logs how many actions really succeeded, so a passing run can be checked for real
coverage instead of silently doing nothing:

```
coverage (last run) deposits/mints/withdrawals/redemptions:
  27 5 11 9
```

## Limitations

Read these before relying on a green run:

- **Passing is evidence, not proof.** Fuzzing explores a huge number of sequences, but it cannot prove the
  absence of bugs. Use it alongside manual review.
- **It tests the ERC4626 surface only.** Access control, upgradeability, oracles, reentrancy through
  external integrations and strategy logic are out of its view.
- **Assets are funded with forge-std's `deal`.** This works for standard ERC20s. Rebasing, fee-on-transfer
  or otherwise non-standard assets need a custom handler.
- **Default yield is a balance increase.** Vaults whose assets live elsewhere should disable
  `_assetsHeldByVault()` and provide their own `simulateYield`.

## Running this repo

Tested on Foundry 1.5 and 1.8 (CI is pinned to 1.8.5). Newer Foundry versions run all invariants of a contract
as one combined campaign, so `forge test` reports fewer, grouped results; the detection script runs each
check separately so its "caught by" column stays exact on any version.

```bash
git clone --recursive https://github.com/keldxd/erc4626-invariants.git
cd erc4626-invariants
forge test -vv                            # reference vaults: everything passes
python3 scripts/detection_matrix.py       # seeded-bug vaults: every bug is caught
```

## Layout

```
src/ERC4626InvariantSuite.sol   base test contract you inherit
src/ERC4626Handler.sol          multi-user action driver and spec checks
test/reference/                 correct vaults (must pass)
test/detection/                 seeded-bug vaults (must fail, run under FOUNDRY_PROFILE=detection)
test/vaults/                    the reference and seeded-bug vault contracts
scripts/detection_matrix.py     regenerates the detection matrix, fails if a bug slips through
```

## License

MIT
