// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Vault} from "../src/Vault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Tests for the admin-controlled ERC20 payout Vault: open deposits, owner-only payouts,
///         and atomic batch distribution (the on-chain side of the admin table's "Add Transfer").
contract VaultTest is Test {
    MockERC20 internal token;
    Vault internal vault;

    address internal admin = makeAddr("admin");
    address internal funder = makeAddr("funder");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        token = new MockERC20("Mock USDT", "mUSDT");
        vault = new Vault(token, admin);
        // Pre-fund the vault with 1,000 tokens via a plain transfer (the "fees routed here" path).
        token.mint(address(vault), 1_000e18);
    }

    // ----------------------------------------------------------------------------------
    // Constructor / config
    // ----------------------------------------------------------------------------------

    function test_Constructor_SetsTokenAndAdmin() public view {
        assertEq(address(vault.i_token()), address(token), "token wired");
        assertEq(vault.owner(), admin, "admin is the owner");
        assertEq(vault.balance(), 1_000e18, "pre-funded balance");
    }

    function test_Constructor_RevertsOnZeroToken() public {
        vm.expectRevert(Vault.Vault__ZeroToken.selector);
        new Vault(MockERC20(address(0)), admin);
    }

    function test_Constructor_RevertsOnZeroAdmin() public {
        // Ownable rejects the zero owner with its own error.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Vault(token, address(0));
    }

    // ----------------------------------------------------------------------------------
    // Deposits (open to anyone)
    // ----------------------------------------------------------------------------------

    function test_Deposit_AnyonePullsTokensIn() public {
        token.mint(funder, 500e18);
        vm.startPrank(funder);
        token.approve(address(vault), 500e18);
        vault.deposit(500e18);
        vm.stopPrank();

        assertEq(vault.balance(), 1_500e18, "deposit added to the pool");
        assertEq(token.balanceOf(funder), 0, "funder paid in");
    }

    function test_Deposit_RevertsOnZero() public {
        vm.expectRevert(Vault.Vault__ZeroAmount.selector);
        vault.deposit(0);
    }

    // ----------------------------------------------------------------------------------
    // Single payout (admin only)
    // ----------------------------------------------------------------------------------

    function test_Payout_AdminPaysUser() public {
        vm.prank(admin);
        vault.payout(alice, 250e18);
        assertEq(token.balanceOf(alice), 250e18, "alice paid");
        assertEq(vault.balance(), 750e18, "vault debited");
    }

    function test_Payout_RevertsForNonAdmin() public {
        vm.prank(alice); // not the owner
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.payout(alice, 1e18);
    }

    function test_Payout_RevertsOnInsufficientBalance() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault__InsufficientBalance.selector, 2_000e18, 1_000e18));
        vault.payout(alice, 2_000e18);
    }

    function test_Payout_RevertsOnZeroRecipientOrAmount() public {
        vm.startPrank(admin);
        vm.expectRevert(Vault.Vault__ZeroRecipient.selector);
        vault.payout(address(0), 1e18);
        vm.expectRevert(Vault.Vault__ZeroAmount.selector);
        vault.payout(alice, 0);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------------------------
    // Batch distribute (admin only) — the "Add Transfer" rows
    // ----------------------------------------------------------------------------------

    function test_Distribute_PaysManyInOneCall() public {
        address[] memory to = new address[](3);
        uint256[] memory amt = new uint256[](3);
        (to[0], amt[0]) = (alice, 100e18);
        (to[1], amt[1]) = (bob, 200e18);
        (to[2], amt[2]) = (carol, 300e18);

        vm.prank(admin);
        vault.distribute(to, amt);

        assertEq(token.balanceOf(alice), 100e18, "alice paid");
        assertEq(token.balanceOf(bob), 200e18, "bob paid");
        assertEq(token.balanceOf(carol), 300e18, "carol paid");
        assertEq(vault.balance(), 400e18, "vault debited by the total (600)");
    }

    function test_Distribute_RevertsForNonAdmin() public {
        address[] memory to = new address[](1);
        uint256[] memory amt = new uint256[](1);
        (to[0], amt[0]) = (alice, 1e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.distribute(to, amt);
    }

    function test_Distribute_RevertsOnLengthMismatch() public {
        address[] memory to = new address[](2);
        uint256[] memory amt = new uint256[](1);
        to[0] = alice;
        to[1] = bob;
        amt[0] = 1e18;

        vm.prank(admin);
        vm.expectRevert(Vault.Vault__LengthMismatch.selector);
        vault.distribute(to, amt);
    }

    function test_Distribute_RevertsOnEmptyBatch() public {
        address[] memory to = new address[](0);
        uint256[] memory amt = new uint256[](0);
        vm.prank(admin);
        vm.expectRevert(Vault.Vault__EmptyBatch.selector);
        vault.distribute(to, amt);
    }

    /// @notice Atomicity: if the batch total exceeds the balance, the WHOLE call reverts and
    ///         nobody is paid — even recipients listed before the offending entry.
    function test_Distribute_IsAtomic_NoPartialPayment() public {
        address[] memory to = new address[](2);
        uint256[] memory amt = new uint256[](2);
        (to[0], amt[0]) = (alice, 600e18); // payable on its own
        (to[1], amt[1]) = (bob, 600e18); // pushes total (1200) past the 1000 balance

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Vault.Vault__InsufficientBalance.selector, 1_200e18, 1_000e18));
        vault.distribute(to, amt);

        // No partial payment: alice (listed first) got nothing, vault untouched.
        assertEq(token.balanceOf(alice), 0, "alice not paid");
        assertEq(token.balanceOf(bob), 0, "bob not paid");
        assertEq(vault.balance(), 1_000e18, "vault balance unchanged");
    }

    function test_Distribute_RevertsOnZeroRecipientInBatch() public {
        address[] memory to = new address[](2);
        uint256[] memory amt = new uint256[](2);
        (to[0], amt[0]) = (alice, 1e18);
        (to[1], amt[1]) = (address(0), 1e18);

        vm.prank(admin);
        vm.expectRevert(Vault.Vault__ZeroRecipient.selector);
        vault.distribute(to, amt);
        assertEq(token.balanceOf(alice), 0, "no payment when a row is invalid");
    }

    // ----------------------------------------------------------------------------------
    // Admin handoff
    // ----------------------------------------------------------------------------------

    function test_TransferOwnership_HandsOffAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        vault.transferOwnership(newAdmin);
        assertEq(vault.owner(), newAdmin, "ownership transferred");

        // Old admin can no longer pay out; new admin can.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        vault.payout(alice, 1e18);

        vm.prank(newAdmin);
        vault.payout(alice, 1e18);
        assertEq(token.balanceOf(alice), 1e18, "new admin can pay");
    }

    function test_RenounceOwnership_IsDisabled() public {
        vm.prank(admin);
        vm.expectRevert(Vault.Vault__RenounceDisabled.selector);
        vault.renounceOwnership();
        assertEq(vault.owner(), admin, "still owned (funds not frozen)");
    }
}
