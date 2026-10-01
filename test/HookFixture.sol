// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AntiSnipeHook} from "../src/AntiSnipeHook.sol";
import {AntiSnipeToken} from "../src/AntiSnipeToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MineHook} from "../script/MineHook.s.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

abstract contract HookFixture is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    uint256 internal constant START = 1_000_000;
    uint160 internal constant FLAGS = HookFlags.AFTER_INITIALIZE | HookFlags.BEFORE_SWAP;

    PoolManager internal manager;
    AntiSnipeHook internal hook;
    ERC20 internal token0;
    ERC20 internal token1;
    PoolKey internal key;

    function setUp() public virtual {
        vm.warp(START);
        manager = new PoolManager(address(this));
        // Exercise the delivered mining helper and the production constructor, without etching code.
        (address predicted, bytes32 salt) = new MineHook().run(manager, address(this));
        hook = new AntiSnipeHook{salt: salt}(manager);
        assertEq(address(hook), predicted);
        assertTrue(HookFlags.matches(predicted, FLAGS));

        ERC20 a = new AntiSnipeToken();
        ERC20 b = new MockERC20("Quote", "QUOTE", 1_000_000_000 ether);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function quote(PoolKey memory pool) internal returns (uint24 fee) {
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 overrideFee) =
            hook.beforeSwap(address(this), pool, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), "");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertTrue(overrideFee & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0);
        return overrideFee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }

    function assertNoEscapeOpcodes(address target) internal view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2, "escape opcode in runtime");
        }
    }
}
