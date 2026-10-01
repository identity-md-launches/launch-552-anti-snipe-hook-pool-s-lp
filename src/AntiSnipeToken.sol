// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed launch supply, minted entirely to the deploying factory.
contract AntiSnipeToken is ERC20 {
    constructor() ERC20("AntiSnipe", "SNIPE") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

