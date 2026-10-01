// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AntiSnipeToken} from "../src/AntiSnipeToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract AntiSnipeTokenTest is Test {
    AntiSnipeToken internal token;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        token = new AntiSnipeToken();
    }

    function test_fixedSupplyAndMetadata() public view {
        assertEq(token.name(), "AntiSnipe");
        assertEq(token.symbol(), "SNIPE");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_mintsToAnyDeployer(address deployer) public {
        vm.assume(deployer != address(0));
        vm.prank(deployer);
        AntiSnipeToken another = new AntiSnipeToken();
        assertEq(another.balanceOf(deployer), SUPPLY);
        assertEq(another.totalSupply(), SUPPLY);
    }

    function testFuzz_transferMovesExactAmountAndConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromConsumesAllowance() public {
        assertTrue(token.approve(ALICE, 10 ether));
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 3 ether));
        assertEq(token.allowance(address(this), ALICE), 7 ether);
        assertEq(token.balanceOf(BOB), 3 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 3 ether);
    }

    function test_transferCannotSpendAnotherAccountWithoutApproval() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(address(this), BOB, 1);
    }

    function test_rejectsOverdraftAndZeroRecipient() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transfer(BOB, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferAndZeroTransferDoNotChangeSupply() public {
        assertTrue(token.transfer(address(this), SUPPLY));
        assertTrue(token.transfer(ALICE, 0));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_noMintBurnOwnerPauseFeeOrUpgradeSelectors() public {
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "burn(uint256)",
            "setFee(uint256)",
            "owner()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, type(uint128).max);
            (bool deployerOk,) = address(token).call(data);
            assertFalse(deployerOk, signatures[i]);
            vm.prank(ALICE);
            (bool attackerOk,) = address(token).call(data);
            assertFalse(attackerOk, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_runtimeHasNoEscapeOpcodes() public view {
        bytes memory code = address(token).code;
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
