// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {AntiSnipeHook} from "../src/AntiSnipeHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MineHook} from "../script/MineHook.s.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract AntiSnipeHookTest is HookFixture {
    function test_permissionsMatchDeployedAddress() public view {
        Hooks.Permissions memory expected;
        expected.afterInitialize = true;
        expected.beforeSwap = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(HookFlags.flagsOf(address(hook)), 0x1080);
        assertEq(address(hook.poolManager()), address(manager));
        assertNoEscapeOpcodes(address(hook));
    }

    function test_windowStartsAtPoolInitializationNotHookDeployment() public {
        vm.warp(START + 2 days);
        vm.expectEmit(true, false, false, true, address(hook));
        emit AntiSnipeHook.AntiSnipeWindowStarted(key.toId(), START + 2 days + 1 hours);
        assertEq(manager.initialize(key, SQRT_PRICE_1_1), 0);
        assertEq(hook.antiSnipeEndsAt(key.toId()), START + 2 days + 1 hours);
        assertEq(quote(key), 10_000);
    }

    function test_feeAtInitializationAndHourBoundary() public {
        manager.initialize(key, SQRT_PRICE_1_1);
        assertEq(quote(key), 10_000);
        vm.warp(START + 3599);
        assertEq(quote(key), 10_000);
        vm.warp(START + 3600);
        assertEq(quote(key), 3_000);
        vm.warp(START + 3601);
        assertEq(quote(key), 3_000);
        vm.warp(START + 3650 days);
        assertEq(quote(key), 3_000);
    }

    function testFuzz_feeIndependentOfSenderDataAndSwapParameters(
        uint64 elapsed,
        bool direction,
        int128 amount,
        address sender,
        bytes calldata hookData
    ) public {
        manager.initialize(key, SQRT_PRICE_1_1);
        vm.warp(START + uint256(elapsed));
        vm.record();
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            hook.beforeSwap(sender, key, SwapParams(direction, amount, SQRT_PRICE_1_1 / 2), hookData);
        (, bytes32[] memory writes) = vm.accesses(address(hook));
        assertEq(writes.length, 0, "beforeSwap must not write storage");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, (elapsed < 3600 ? uint24(10_000) : uint24(3_000)) | 0x400000);
        assertEq(hook.antiSnipeEndsAt(key.toId()), START + 3600);
    }

    function testFuzz_unauthorizedCallbacksCannotStartOrResetTimer(address caller) public {
        vm.assume(caller != address(manager));
        vm.startPrank(caller);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterInitialize(address(manager), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(address(manager), key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), "");
        vm.stopPrank();
        assertEq(hook.antiSnipeEndsAt(key.toId()), 0);
    }

    function test_uninitializedPoolCannotReceiveFeeQuote() public {
        vm.prank(address(manager));
        vm.expectRevert(AntiSnipeHook.PoolNotInitialized.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), "");
    }

    function test_staticFeeInitializationRevertsAndRollsBack() public {
        key.fee = 3_000;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(AntiSnipeHook.DynamicFeeRequired.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(key, SQRT_PRICE_1_1);
        assertEq(hook.antiSnipeEndsAt(key.toId()), 0);
        key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        manager.initialize(key, SQRT_PRICE_1_1);
        assertEq(quote(key), 10_000);
    }

    function test_callbackRejectsStaticFeeAndMalformedDynamicFlag() public {
        uint24[3] memory fees = [uint24(3_000), uint24(0), uint24(0x800000 | 3000)];
        for (uint256 i; i < fees.length; ++i) {
            key.fee = fees[i];
            vm.startPrank(address(manager));
            vm.expectRevert(AntiSnipeHook.DynamicFeeRequired.selector);
            hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
            vm.expectRevert(AntiSnipeHook.DynamicFeeRequired.selector);
            hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), "");
            vm.stopPrank();
        }
    }

    function test_wrongHookKeyRejected() public {
        key.hooks = IHooks(address(0));
        vm.startPrank(address(manager));
        vm.expectRevert(AntiSnipeHook.WrongHook.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(AntiSnipeHook.WrongHook.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), "");
        vm.stopPrank();
    }

    function test_reinitializationCannotRestartExpiredWindow() public {
        manager.initialize(key, SQRT_PRICE_1_1);
        vm.warp(START + 2 hours);
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        manager.initialize(key, SQRT_PRICE_1_1);
        vm.prank(address(manager));
        vm.expectRevert(AntiSnipeHook.PoolAlreadyInitialized.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        assertEq(hook.antiSnipeEndsAt(key.toId()), START + 3600);
        assertEq(quote(key), 3000);
    }

    function test_poolsHaveIndependentClocks() public {
        manager.initialize(key, SQRT_PRICE_1_1);
        vm.warp(START + 1800);
        PoolKey memory other = key;
        other.tickSpacing = 120;
        manager.initialize(other, SQRT_PRICE_1_1);
        vm.warp(START + 3600);
        assertEq(quote(key), 3000);
        assertEq(quote(other), 10_000);
        vm.warp(START + 5400);
        assertEq(quote(other), 3000);
        assertEq(hook.antiSnipeEndsAt(key.toId()), START + 3600);
        assertEq(hook.antiSnipeEndsAt(other.toId()), START + 5400);
    }

    function test_initializationAtTimestampZeroIsSupported() public {
        vm.warp(0);
        manager.initialize(key, SQRT_PRICE_1_1);
        assertEq(hook.antiSnipeEndsAt(key.toId()), 3600);
        assertEq(quote(key), 10_000);
        vm.warp(3600);
        assertEq(quote(key), 3000);
    }

    function test_predictedPoolCannotInitializeBeforeHookExists() public {
        (address predicted,) = new MineHook().run(manager, address(this));
        assertEq(predicted.code.length, 0);
        key.hooks = IHooks(predicted);
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_constructorRejectsWrongPermissionAddress() public {
        bytes32 codeHash = keccak256(abi.encodePacked(type(AntiSnipeHook).creationCode, abi.encode(manager)));
        bytes32 salt;
        address predicted;
        do {
            salt = bytes32(uint256(salt) + 1);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, codeHash))))
            );
        } while (HookFlags.matches(predicted, FLAGS));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new AntiSnipeHook{salt: salt}(manager);
    }

    function test_constructorRejectsZeroOrCodelessManager() public {
        IPoolManager[2] memory invalid = [IPoolManager(address(0)), IPoolManager(address(0x1234))];
        for (uint256 i; i < invalid.length; ++i) {
            (, bytes32 salt) = new MineHook().run(invalid[i], address(this));
            vm.expectRevert(AntiSnipeHook.InvalidPoolManager.selector);
            new AntiSnipeHook{salt: salt}(invalid[i]);
        }
    }

    function test_disabledCallbacksRevertEvenFromManager() public {
        ModifyLiquidityParams memory liquidity = ModifyLiquidityParams(-60, 60, 1 ether, 0);
        SwapParams memory swap = SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2);
        BalanceDelta zero = BalanceDelta.wrap(0);
        bytes[8] memory calls = [
            abi.encodeCall(IHooks.beforeInitialize, (address(this), key, SQRT_PRICE_1_1)),
            abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), key, liquidity, "")),
            abi.encodeCall(IHooks.afterAddLiquidity, (address(this), key, liquidity, zero, zero, "")),
            abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), key, liquidity, "")),
            abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), key, liquidity, zero, zero, "")),
            abi.encodeCall(IHooks.afterSwap, (address(this), key, swap, zero, "")),
            abi.encodeCall(IHooks.beforeDonate, (address(this), key, 1, 1, "")),
            abi.encodeCall(IHooks.afterDonate, (address(this), key, 1, 1, ""))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool unauthorized, bytes memory authError) = address(hook).call(calls[i]);
            assertFalse(unauthorized);
            assertEq(authError, abi.encodeWithSelector(ImmutableState.NotPoolManager.selector));
            vm.prank(address(manager));
            (bool enabled, bytes memory disabledError) = address(hook).call(calls[i]);
            assertFalse(enabled);
            assertEq(disabledError, abi.encodeWithSelector(BaseHook.HookNotImplemented.selector));
        }
    }

    function test_noAdministrativeSelectors() public {
        manager.initialize(key, SQRT_PRICE_1_1);
        string[7] memory signatures = [
            "owner()",
            "transferOwnership(address)",
            "setFee(uint24)",
            "pause()",
            "unpause()",
            "upgradeTo(address)",
            "resetTimer(bytes32)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(signatures[i], address(this)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(hook.antiSnipeEndsAt(key.toId()), START + 3600);
    }
}
