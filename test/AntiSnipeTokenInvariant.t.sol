// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AntiSnipeToken} from "src/AntiSnipeToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev A closed set of holders lets the invariant account for every unit of supply.
contract AntiSnipeTokenHandler is Test {
    AntiSnipeToken public immutable token;
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    address[4] public actors = [address(0xA11CE), address(0xB0B), address(0xCAFE), address(0xD00D)];
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(AntiSnipeToken token_) {
        token = token_;
        expectedBalance[actors[0]] = SUPPLY;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = unlimited ? type(uint256).max : bound(amount, 0, SUPPLY);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        uint256 amount = bound(amountSeed, 0, allowance < balance ? allowance : balance);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowance != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    function rejectOverdraft(uint256 fromSeed, uint256 toSeed) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = expectedBalance[from];
        vm.prank(from);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, balance + 1)
        );
        token.transfer(to, balance + 1);
    }

    function rejectUnapprovedSpend(uint256 ownerSeed, uint256 spenderSeed) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        // Revoke any prior approval so this checks revocation after arbitrary successful spends too.
        vm.prank(owner);
        assertTrue(token.approve(spender, 0));
        expectedAllowance[owner][spender] = 0;
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1)
        );
        token.transferFrom(owner, spender, 1);
    }

    function rejectZeroRecipient(uint256 fromSeed, uint256 amountSeed) public {
        address from = actors[fromSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract AntiSnipeTokenInvariantTest is Test {
    AntiSnipeToken internal token;
    AntiSnipeTokenHandler internal handler;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new AntiSnipeToken();
        handler = new AntiSnipeTokenHandler(token);
        assertTrue(token.transfer(handler.actors(0), SUPPLY));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.rejectOverdraft.selector;
        selectors[4] = handler.rejectUnapprovedSpend.selector;
        selectors[5] = handler.rejectZeroRecipient.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_fixedSupplyEqualsAllBalances() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor), "transfer ledger mismatch");
            sum += balance;
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    function invariant_allowancesOnlyChangeByApprovalOrAuthorizedSpend() public view {
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
    }

    function test_zeroOneAndFullSupplyTransfers() public {
        handler.transfer(0, 1, 0);
        handler.transfer(0, 1, 1);
        handler.transfer(0, 1, SUPPLY - 1);
        assertEq(token.balanceOf(handler.actors(0)), 0);
        assertEq(token.balanceOf(handler.actors(1)), SUPPLY);
        handler.transfer(1, 1, SUPPLY);
        handler.transfer(1, 0, SUPPLY);
        invariant_fixedSupplyEqualsAllBalances();
    }

    function test_infiniteApprovalSurvivesFullSupplySpendThenRevocation() public {
        handler.approve(0, 1, 0, true);
        handler.transferFrom(0, 1, 2, SUPPLY);
        assertEq(token.balanceOf(handler.actors(2)), SUPPLY);
        assertEq(token.allowance(handler.actors(0), handler.actors(1)), type(uint256).max);
        handler.transfer(2, 0, SUPPLY);
        handler.rejectUnapprovedSpend(0, 1);
        invariant_fixedSupplyEqualsAllBalances();
        invariant_allowancesOnlyChangeByApprovalOrAuthorizedSpend();
    }

    function test_failedTransferFromRestoresAllowance() public {
        address owner = handler.actors(1); // Empty balance, but a valid allowance.
        address spender = handler.actors(2);
        handler.approve(1, 2, 1, false);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, 0, 1));
        token.transferFrom(owner, spender, 1);
        invariant_fixedSupplyEqualsAllBalances();
        invariant_allowancesOnlyChangeByApprovalOrAuthorizedSpend();
    }

    function test_zeroAddressCannotReceiveEvenZeroOrBeApproved() public {
        handler.rejectZeroRecipient(0, 0);
        vm.prank(handler.actors(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), type(uint256).max);
        invariant_fixedSupplyEqualsAllBalances();
        invariant_allowancesOnlyChangeByApprovalOrAuthorizedSpend();
    }
}
