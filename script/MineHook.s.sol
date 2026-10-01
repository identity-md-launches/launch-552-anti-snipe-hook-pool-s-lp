// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AntiSnipeHook} from "../src/AntiSnipeHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

/// @notice Computes CREATE2 parameters for the supplied factory and PoolManager; never broadcasts.
contract MineHook {
    function run(IPoolManager manager, address create2Deployer)
        external
        view
        returns (address hookAddress, bytes32 salt)
    {
        return HookMiner.find(
            create2Deployer,
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG,
            type(AntiSnipeHook).creationCode,
            abi.encode(manager)
        );
    }
}

