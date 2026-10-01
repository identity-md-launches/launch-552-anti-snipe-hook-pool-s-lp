// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Charges a 1% LP fee for one hour after each pool initializes, then 0.3% forever.
/// @dev No administrator, token movements, custom deltas, or swap-time storage writes.
contract AntiSnipeHook is BaseHook {
    using LPFeeLibrary for uint24;

    error InvalidPoolManager();
    error WrongHook();
    error DynamicFeeRequired();
    error PoolAlreadyInitialized();
    error PoolNotInitialized();

    uint24 public constant INITIAL_LP_FEE = 10_000;
    uint24 public constant STANDARD_LP_FEE = 3_000;
    uint256 public constant ANTI_SNIPE_DURATION = 1 hours;

    /// @notice One write per pool. Zero means uninitialized; timestamps of zero are supported.
    mapping(PoolId poolId => uint256 endsAt) public antiSnipeEndsAt;

    event AntiSnipeWindowStarted(PoolId indexed poolId, uint256 endsAt);

    constructor(IPoolManager manager) BaseHook(manager) {
        if (address(manager) == address(0) || address(manager).code.length == 0) revert InvalidPoolManager();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterInitialize = true;
        permissions.beforeSwap = true;
    }

    /// @dev BaseHook authenticates the PoolManager before dispatching this callback.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        override
        returns (bytes4)
    {
        _validatePool(key);
        PoolId poolId = key.toId();
        if (antiSnipeEndsAt[poolId] != 0) revert PoolAlreadyInitialized();

        uint256 endsAt = block.timestamp + ANTI_SNIPE_DURATION;
        antiSnipeEndsAt[poolId] = endsAt;
        emit AntiSnipeWindowStarted(poolId, endsAt);
        return IHooks.afterInitialize.selector;
    }

    /// @dev The override flag makes the returned fee apply to this swap, without updating slot0.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validatePool(key);
        uint256 endsAt = antiSnipeEndsAt[key.toId()];
        if (endsAt == 0) revert PoolNotInitialized();

        uint24 fee = block.timestamp < endsAt ? INITIAL_LP_FEE : STANDARD_LP_FEE;
        return
            (
                IHooks.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
    }

    function _validatePool(PoolKey calldata key) private view {
        if (address(key.hooks) != address(this)) revert WrongHook();
        if (!key.fee.isDynamicFee()) revert DynamicFeeRequired();
    }
}

