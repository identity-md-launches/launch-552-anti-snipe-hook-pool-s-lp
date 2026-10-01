// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./HookFixture.sol";
import {AntiSnipeHook} from "src/AntiSnipeHook.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";

/// @dev Real pools and settlement; the reference pool has no callbacks and uses its stored LP fee.
contract AntiSnipeSequenceHandler is Test {
    using StateLibrary for IPoolManager;

    uint160 internal constant PRICE = 1 << 96;
    int256 internal constant LIQUIDITY = 1_000_000 ether;
    // Low 14 bits are clear. v4 permits a callback-free, nonzero hook address for dynamic fee pools.
    address internal constant REFERENCE_FEE_SETTER = address(0x4000);

    IPoolManager public immutable manager;
    AntiSnipeHook public immutable hook;
    ERC20 public immutable token0;
    ERC20 public immutable token1;
    PoolSwapTest public immutable swapRouter;
    PoolModifyLiquidityTest public immutable liquidityRouter;
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCAFE)];
    PoolKey[2] internal pools;
    uint256[2] public expectedEnd;
    int256 public expectedReserve0;
    int256 public expectedReserve1;

    constructor(
        IPoolManager manager_,
        AntiSnipeHook hook_,
        ERC20 token0_,
        ERC20 token1_,
        PoolKey memory key_
    ) {
        manager = manager_;
        hook = hook_;
        token0 = token0_;
        token1 = token1_;
        swapRouter = new PoolSwapTest(manager_);
        liquidityRouter = new PoolModifyLiquidityTest(manager_);
        pools[0] = key_;
        key_.tickSpacing = 120;
        pools[1] = key_;
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        for (uint256 i; i < actors.length; ++i) {
            vm.startPrank(actors[i]);
            token0.approve(address(swapRouter), type(uint256).max);
            token1.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    function pool(uint256 index) public view returns (PoolKey memory) {
        return pools[index];
    }

    function referencePool(uint256 index) public view returns (PoolKey memory result) {
        result = pools[index];
        result.hooks = IHooks(REFERENCE_FEE_SETTER);
    }

    function initialize(uint256 poolSeed) public {
        uint256 index = poolSeed % pools.length;
        if (expectedEnd[index] != 0) {
            vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
            manager.initialize(pools[index], PRICE);
            return;
        }
        _initialize(index);
    }

    function _initialize(uint256 index) internal {
        manager.initialize(pools[index], PRICE);
        manager.initialize(referencePool(index), PRICE);
        expectedEnd[index] = block.timestamp + 3600;
        _modifyBoth(index, LIQUIDITY, bytes32(0));
    }

    function advanceTime(uint256 secondsSeed) public {
        // Short jumps retain many early-window trades while longer sequences cross the hour.
        vm.warp(block.timestamp + bound(secondsSeed, 0, 900));
    }

    function trade(uint256 poolSeed, uint256 actorSeed, uint256 amountSeed, bool direction, bool exactOutput)
        public
    {
        uint256 index = poolSeed % pools.length;
        if (expectedEnd[index] == 0) _initialize(index);
        uint256 amount = bound(amountSeed, 1, 100 ether);
        SwapParams memory params = SwapParams(
            direction, exactOutput ? int256(amount) : -int256(amount), direction ? PRICE / 2 : PRICE * 2
        );
        PoolKey memory referenceKey = referencePool(index);
        // Independent execution path: set slot0 on the reference, never on the production pool.
        vm.prank(REFERENCE_FEE_SETTER);
        manager.updateDynamicLPFee(referenceKey, block.timestamp < expectedEnd[index] ? 10_000 : 3_000);

        address actor = actors[actorSeed % actors.length];
        vm.record();
        vm.prank(actor);
        BalanceDelta actual =
            swapRouter.swap(pools[index], params, PoolSwapTest.TestSettings(false, false), "");
        (, bytes32[] memory writes) = vm.accesses(address(hook));
        assertEq(writes.length, 0, "a swap wrote hook storage");
        vm.prank(actor);
        BalanceDelta expected =
            swapRouter.swap(referenceKey, params, PoolSwapTest.TestSettings(false, false), "");
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(expected), "executed fee diverged");
        _account(actual);
        _account(expected);
        assertEquivalent(index);
    }

    function collectFees(uint256 poolSeed) public {
        uint256 index = poolSeed % pools.length;
        if (expectedEnd[index] == 0) _initialize(index);
        _modifyBoth(index, 0, bytes32(0));
        assertEquivalent(index);
    }

    function liquidityRoundTrip(uint256 poolSeed, uint256 liquiditySeed) public {
        uint256 index = poolSeed % pools.length;
        if (expectedEnd[index] == 0) _initialize(index);
        // Use a separate, initially empty position: no accrued fees can masquerade as rounding profit.
        // The v4 test router requires a nonzero payout on removal, hence the minimum liquidity.
        int256 amount = int256(bound(liquiditySeed, 1e6, 1000 ether));
        uint256 before0 = token0.balanceOf(address(this));
        uint256 before1 = token1.balanceOf(address(this));
        _modifyBoth(index, amount, bytes32(uint256(1)));
        _modifyBoth(index, -amount, bytes32(uint256(1)));
        assertLe(token0.balanceOf(address(this)), before0, "round trip created token0");
        assertLe(token1.balanceOf(address(this)), before1, "round trip created token1");
        assertEquivalent(index);
    }

    function rejectUnauthorizedCallbacks(uint256 poolSeed, uint256 actorSeed) public {
        uint256 index = poolSeed % pools.length;
        vm.startPrank(actors[actorSeed % actors.length]);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.afterInitialize(address(manager), pools[index], PRICE, 0);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(address(manager), pools[index], SwapParams(true, -1 ether, PRICE / 2), "");
        vm.expectRevert(IPoolManager.UnauthorizedDynamicLPFeeUpdate.selector);
        manager.updateDynamicLPFee(pools[index], 1);
        vm.stopPrank();
    }

    function _modifyBoth(uint256 index, int256 amount, bytes32 salt) internal {
        ModifyLiquidityParams memory params = ModifyLiquidityParams(-600, 600, amount, salt);
        BalanceDelta actual = liquidityRouter.modifyLiquidity(pools[index], params, "");
        BalanceDelta expected = liquidityRouter.modifyLiquidity(referencePool(index), params, "");
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(expected), "LP proceeds diverged");
        _account(actual);
        _account(expected);
    }

    function _account(BalanceDelta delta) internal {
        // Delta is from the user's perspective; the manager's reserve changes by its negation.
        expectedReserve0 -= int256(delta.amount0());
        expectedReserve1 -= int256(delta.amount1());
    }

    function assertEquivalent(uint256 index) public view {
        (uint160 actualPrice, int24 actualTick,, uint24 storedFee) = manager.getSlot0(pools[index].toId());
        (uint160 expectedPrice, int24 expectedTick,,) = manager.getSlot0(referencePool(index).toId());
        assertEq(actualPrice, expectedPrice, "price diverged");
        assertEq(actualTick, expectedTick, "tick diverged");
        assertEq(storedFee, 0, "hook changed stored LP fee");
        (uint256 actual0, uint256 actual1) = manager.getFeeGrowthGlobals(pools[index].toId());
        (uint256 expected0, uint256 expected1) = manager.getFeeGrowthGlobals(referencePool(index).toId());
        assertEq(actual0, expected0, "token0 LP fee growth diverged");
        assertEq(actual1, expected1, "token1 LP fee growth diverged");
        assertEq(manager.getLiquidity(pools[index].toId()), uint256(LIQUIDITY));
        assertEq(manager.getLiquidity(referencePool(index).toId()), uint256(LIQUIDITY));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract AntiSnipeSequenceInvariantTest is HookFixture {
    using TransientStateLibrary for IPoolManager;

    AntiSnipeSequenceHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new AntiSnipeSequenceHandler(manager, hook, token0, token1, key);
        token0.transfer(address(handler), 100_000_000 ether);
        token1.transfer(address(handler), 100_000_000 ether);
        for (uint256 i; i < 3; ++i) {
            token0.transfer(handler.actors(i), 10_000_000 ether);
            token1.transfer(handler.actors(i), 10_000_000 ether);
        }
        handler.initialize(0);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.initialize.selector;
        selectors[1] = handler.advanceTime.selector;
        selectors[2] = handler.trade.selector;
        selectors[3] = handler.collectFees.selector;
        selectors[4] = handler.liquidityRoundTrip.selector;
        selectors[5] = handler.rejectUnauthorizedCallbacks.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_eachPoolKeepsItsOriginalWindowAndFee() public {
        for (uint256 i; i < 2; ++i) {
            PoolKey memory current = handler.pool(i);
            uint256 end = handler.expectedEnd(i);
            assertEq(hook.antiSnipeEndsAt(current.toId()), end, "pool clock reset or contaminated");
            if (end == 0) {
                vm.prank(address(manager));
                vm.expectRevert(AntiSnipeHook.PoolNotInitialized.selector);
                hook.beforeSwap(address(this), current, SwapParams(true, -1, SQRT_PRICE_1_1 / 2), "");
            } else {
                assertEq(quote(current), block.timestamp < end ? 10_000 : 3_000);
                handler.assertEquivalent(i);
            }
        }
    }

    function invariant_settlementConservesAllValueAndLeavesNoHookCustody() public view {
        assertGe(handler.expectedReserve0(), 0);
        assertGe(handler.expectedReserve1(), 0);
        assertEq(token0.balanceOf(address(manager)), uint256(handler.expectedReserve0()));
        assertEq(token1.balanceOf(address(manager)), uint256(handler.expectedReserve1()));
        _assertConserved(token0);
        _assertConserved(token1);
        assertEq(address(hook).balance, 0);
        IPoolManager poolManager = IPoolManager(address(manager));
        assertFalse(poolManager.isUnlocked());
        assertEq(poolManager.getNonzeroDeltaCount(), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency1), 0);
    }

    function _assertConserved(ERC20 token) internal view {
        uint256 sum = token.balanceOf(address(this)) + token.balanceOf(address(handler))
            + token.balanceOf(address(manager));
        for (uint256 i; i < 3; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(handler.swapRouter())), 0);
        assertEq(token.balanceOf(address(handler.liquidityRouter())), 0);
    }

    function test_sequenceAcrossStaggeredHourBoundaries() public {
        handler.trade(0, 0, 1 ether, true, false);
        handler.advanceTime(900);
        handler.advanceTime(900);
        handler.initialize(1);
        handler.advanceTime(900);
        handler.advanceTime(899);
        handler.trade(0, 1, 1, false, false);
        assertEq(quote(handler.pool(0)), 10_000);
        handler.advanceTime(1);
        handler.trade(0, 2, 1 ether, false, true);
        handler.trade(1, 0, 1 ether, true, true);
        assertEq(quote(handler.pool(0)), 3_000);
        assertEq(quote(handler.pool(1)), 10_000);
        handler.initialize(0); // Cannot restart the expired window.
        handler.collectFees(0);
        handler.liquidityRoundTrip(0, 1000 ether);
        handler.advanceTime(900);
        handler.advanceTime(900);
        handler.trade(1, 1, 1, false, true);
        assertEq(quote(handler.pool(1)), 3_000);
        invariant_eachPoolKeepsItsOriginalWindowAndFee();
        invariant_settlementConservesAllValueAndLeavesNoHookCustody();
    }
}
