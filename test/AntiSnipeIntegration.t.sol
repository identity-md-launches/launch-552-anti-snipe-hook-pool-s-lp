// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract AntiSnipeIntegrationTest is HookFixture {
    using StateLibrary for IPoolManager;

    int256 internal constant LIQUIDITY = 1_000_000 ether;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;

    function setUp() public override {
        super.setUp();
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        token0.approve(address(swapRouter), 1_000_000 ether);
        token1.approve(address(swapRouter), 1_000_000 ether);
        token0.approve(address(liquidityRouter), 1_000_000 ether);
        token1.approve(address(liquidityRouter), 1_000_000 ether);
        seedPool(key);
    }

    function seedPool(PoolKey memory pool) internal {
        manager.initialize(pool, SQRT_PRICE_1_1);
        liquidityRouter.modifyLiquidity(pool, ModifyLiquidityParams(-600, 600, LIQUIDITY, 0), "");
    }

    function swap(PoolKey memory pool, bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        return swapRouter.swap(
            pool,
            SwapParams(zeroForOne, amount, zeroForOne ? SQRT_PRICE_1_1 / 2 : SQRT_PRICE_1_1 * 2),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    /// @dev Independent oracle: compare actual execution with a plain static-fee pool at the same price
    /// and liquidity. This catches missing override flags, wrong units, delta changes and wrong timing.
    function compareWithStaticFee(uint256 elapsed, bool zeroForOne, bool exactOutput, uint256 amount)
        internal
    {
        PoolKey memory referenceKey = key;
        referenceKey.hooks = IHooks(address(0));
        referenceKey.fee = elapsed < 3600 ? 10_000 : 3_000;
        seedPool(referenceKey);
        vm.warp(START + elapsed);
        {
            int256 specified = exactOutput ? int256(amount) : -int256(amount);
            BalanceDelta actual = swap(key, zeroForOne, specified);
            BalanceDelta expected = swap(referenceKey, zeroForOne, specified);
            assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(expected), "executed fee mismatch");
            assertGt(zeroForOne ? actual.amount1() : actual.amount0(), 0);
        }
        {
            (uint160 price, int24 tick,, uint24 storedFee) =
                IPoolManager(address(manager)).getSlot0(key.toId());
            (uint160 referencePrice, int24 referenceTick,,) =
                IPoolManager(address(manager)).getSlot0(referenceKey.toId());
            assertEq(price, referencePrice);
            assertEq(tick, referenceTick);
            assertEq(storedFee, 0, "fee override must not mutate the manager's stored LP fee");
        }
        (uint256 growth0, uint256 growth1) = IPoolManager(address(manager)).getFeeGrowthGlobals(key.toId());
        (uint256 referenceGrowth0, uint256 referenceGrowth1) =
            IPoolManager(address(manager)).getFeeGrowthGlobals(referenceKey.toId());
        assertEq(growth0, referenceGrowth0);
        assertEq(growth1, referenceGrowth1);
        assertGt(zeroForOne ? growth0 : growth1, 0, "LPs must receive the swap fee");
        assertEq(hook.antiSnipeEndsAt(key.toId()), START + 3600);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);
    }

    function test_exactInputAtInitialization() public {
        compareWithStaticFee(0, true, false, 1 ether);
    }

    function test_exactInputJustBeforeHourInReverseDirection() public {
        compareWithStaticFee(3599, false, false, 1 ether);
    }

    function test_exactInputAtHour() public {
        compareWithStaticFee(3600, true, false, 1 ether);
    }

    function test_exactInputAfterHourInReverseDirection() public {
        compareWithStaticFee(3601, false, false, 1 ether);
    }

    function test_exactOutputBeforeHour() public {
        compareWithStaticFee(3599, true, true, 1 ether);
    }

    function test_exactOutputAtHourInReverseDirection() public {
        compareWithStaticFee(3600, false, true, 1 ether);
    }

    function testFuzz_actualSwapsMatchStaticPool(
        uint32 elapsed,
        bool direction,
        bool exactOutput,
        uint96 amount
    ) public {
        compareWithStaticFee(bound(elapsed, 0, 7200), direction, exactOutput, bound(amount, 1000, 100 ether));
    }

    function test_fullLifecycleEarnsLPFeesAndConservesTokens() public {
        swap(key, true, -1 ether);
        vm.warp(START + 3600);
        swap(key, false, -1 ether);
        BalanceDelta fees = liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, 0, 0), "");
        // One position owns all liquidity. Q128 fee growth truncation can lose at most one minor unit.
        assertApproxEqAbs(fees.amount0(), 0.01 ether, 1);
        assertApproxEqAbs(fees.amount1(), 0.003 ether, 1);
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, -LIQUIDITY, 0), "");
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), 0);
        assertEq(token0.balanceOf(address(this)) + token0.balanceOf(address(manager)), token0.totalSupply());
        assertEq(token1.balanceOf(address(this)) + token1.balanceOf(address(manager)), token1.totalSupply());
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);
        assertEq(hook.antiSnipeEndsAt(key.toId()), START + 3600);
    }

    function test_badPriceLimitRevertsWithoutChangingTimerOrBalances() public {
        uint256 balance = token0.balanceOf(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(
                Pool.PriceLimitAlreadyExceeded.selector, SQRT_PRICE_1_1, SQRT_PRICE_1_1 + 1
            )
        );
        swapRouter.swap(
            key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 + 1), PoolSwapTest.TestSettings(false, false), ""
        );
        assertEq(token0.balanceOf(address(this)), balance);
        assertEq(hook.antiSnipeEndsAt(key.toId()), START + 3600);
    }

    function test_failedSettlementRollsBackSwap() public {
        token0.approve(address(swapRouter), 0);
        uint256 balance = token0.balanceOf(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(swapRouter), 0, 1 ether
            )
        );
        swap(key, true, -1 ether);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, SQRT_PRICE_1_1);
        assertEq(token0.balanceOf(address(this)), balance);
        assertEq(hook.antiSnipeEndsAt(key.toId()), START + 3600);
    }

    function test_noCallerCanChangeStoredLPFee() public {
        vm.expectRevert(IPoolManager.UnauthorizedDynamicLPFeeUpdate.selector);
        manager.updateDynamicLPFee(key, 1);
        assertEq(quote(key), 10_000);
    }
}
