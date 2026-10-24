// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @notice Plain 18-decimal ERC20 used as the vault asset in tests.
contract MockAsset is ERC20 {
    constructor() ERC20("Mock Asset", "MOCK") {}
}
