// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../lib/forge-std/src/Test.sol";
import "../src/DAOMultiSigWallet.sol";

contract MultiSigEOAWalletTest is Test {
    DAOMultiSigWallet wallet;

    address owner1 = makeAddr("owner1");
    address owner2 = makeAddr("owner2");
    address owner3 = makeAddr("owner3");
    address owner4 = makeAddr("owner4");
    address newOwner = makeAddr("newOwner");
    address recipient = makeAddr("recipient");
    address nonOwner = makeAddr("nonOwner");

    address[] initialOwners;
    uint quorumSize = 2;

    event OwnerTrustedBy(address indexed owner, address supporter);
    event OwnerUnTrustedBy(address indexed owner, address supporter);
    event OwnerSubmitted(address indexed newOwner);
    event OwnerConfirmed(address indexed owner);
    event OwnerRevoked(address indexed owner);
    event TransactionSubmitted(
        uint indexed txIndex,
        address indexed to,
        uint value
    );
    event TransactionRevoked(uint indexed txIndex, address indexed revoker);
    event TxConfirmed(
        address indexed confirmer,
        uint indexed txIndex,
        uint confirmations
    );
    event TxQuorumReached(uint indexed txIndex);
    event TransactionExecuted(
        uint indexed txIndex,
        address indexed to,
        uint value
    );

    function setUp() public {
        initialOwners = new address[](3);
        initialOwners[0] = owner1;
        initialOwners[1] = owner2;
        initialOwners[2] = owner3;
        wallet = new DAOMultiSigWallet(initialOwners, quorumSize);

        // Fund the wallet
        vm.deal(address(wallet), 10 ether);
    }

    // Constructor Tests
    function testConstructorSuccess() public view {
        assertEq(wallet.quorum(), quorumSize);
        assertEq(wallet.ownerCount(), 3);
        assertEq(wallet.trustedCount(), 3);

        assertTrue(wallet.owners(owner1));
        assertTrue(wallet.owners(owner2));
        assertTrue(wallet.owners(owner3));
    }

    function testConstructorFailsWithTooFewOwners() public {
        address[] memory tooFewOwners = new address[](2);
        tooFewOwners[0] = owner1;
        tooFewOwners[1] = owner2;

        vm.expectRevert(DAOMultiSigWallet.NotEnoughOwners.selector);
        new DAOMultiSigWallet(tooFewOwners, 2);
    }

    function testConstructorFailsWithInvalidQuorum() public {
        vm.expectRevert(DAOMultiSigWallet.QuorumTooLow.selector);
        new DAOMultiSigWallet(initialOwners, 1);

        vm.expectRevert(DAOMultiSigWallet.QuorumTooHigh.selector);
        new DAOMultiSigWallet(initialOwners, 4);
    }

    function testConstructorFailsWithZeroAddress() public {
        address[] memory ownersWithZero = new address[](3);
        ownersWithZero[0] = owner1;
        ownersWithZero[1] = owner2;
        ownersWithZero[2] = address(0);

        vm.expectRevert(DAOMultiSigWallet.ZeroAddress.selector);
        new DAOMultiSigWallet(ownersWithZero, 2);
    }

    function testConstructorFailsWithDuplicateOwner() public {
        address[] memory ownersWithDuplicate = new address[](3);
        ownersWithDuplicate[0] = owner1;
        ownersWithDuplicate[1] = owner2;
        ownersWithDuplicate[2] = owner1;

        vm.expectRevert(DAOMultiSigWallet.AlreadyOwner.selector);
        new DAOMultiSigWallet(ownersWithDuplicate, 2);
    }

    // Owner Management Tests
    function testSubmitOwner() public {
        vm.prank(owner1);
        vm.expectEmit(true, false, false, false);
        emit OwnerSubmitted(newOwner);
        wallet.submitOwner(newOwner);

        assertTrue(wallet.owners(newOwner));
        assertEq(wallet.ownerCount(), 4);
    }

    function testSubmitOwnerFailsFromNonTrusted() public {
        vm.prank(nonOwner);
        vm.expectRevert(DAOMultiSigWallet.NotTrusted.selector);
        wallet.submitOwner(newOwner);
    }

    function testSubmitOwnerFailsWithExistingOwner() public {
        vm.prank(owner1);
        vm.expectRevert(DAOMultiSigWallet.AlreadyOwner.selector);
        wallet.submitOwner(owner2);
    }

    function testSubmitOwnerFailsWithZeroAddress() public {
        vm.prank(owner1);
        vm.expectRevert(DAOMultiSigWallet.ZeroAddress.selector);
        wallet.submitOwner(address(0));
    }

    function testSupportOwner() public {
        // First submit a new owner
        vm.prank(owner1);
        wallet.submitOwner(newOwner);

        // Support the new owner
        vm.prank(owner2);
        vm.expectEmit(true, true, false, false);
        emit OwnerTrustedBy(newOwner, owner2);
        vm.expectEmit(true, false, false, false);
        emit OwnerConfirmed(newOwner);
        wallet.supportOwner(newOwner);

        assertEq(wallet.trustedCount(), 4);
    }

    function testSupportOwnerFailsForNonExistentOwner() public {
        vm.prank(owner1);
        vm.expectRevert(DAOMultiSigWallet.OwnerNotFound.selector);
        wallet.supportOwner(newOwner);
    }

    function testSupportOwnerFailsWhenAlreadySupporting() public {
        vm.prank(owner1);
        wallet.submitOwner(newOwner);

        vm.prank(owner2);
        wallet.supportOwner(newOwner);

        vm.prank(owner2);
        vm.expectRevert("Already supporting this owner");
        wallet.supportOwner(newOwner);
    }

    function testUnSupportOwner() public {
        // Submit and support a new owner
        vm.prank(owner1);
        wallet.submitOwner(newOwner);

        vm.prank(owner2);
        wallet.supportOwner(newOwner);

        // Add another owner to maintain minimum trusted count
        address anotherOwner = makeAddr("anotherOwner");
        vm.prank(owner1);
        wallet.submitOwner(anotherOwner);
        vm.prank(owner2);
        wallet.supportOwner(anotherOwner);

        // Remove support
        vm.prank(owner2);
        vm.expectEmit(true, true, false, false);
        emit OwnerUnTrustedBy(newOwner, owner2);
        vm.expectEmit(true, false, false, false);
        emit OwnerRevoked(newOwner);
        wallet.unSupportOwner(newOwner);
    }

    function testUnSupportOwnerFailsWhenNotSupporting() public {
        vm.prank(owner1);
        wallet.submitOwner(newOwner);

        vm.prank(owner2);
        vm.expectRevert(DAOMultiSigWallet.NotSupporter.selector);
        wallet.unSupportOwner(newOwner);
    }

    // Transaction Tests
    function testSubmitTransaction() public {
        vm.prank(owner1);
        vm.expectEmit(true, true, false, true);
        emit TransactionSubmitted(0, recipient, 1 ether);
        wallet.submit(recipient, 1 ether, "");

        assertEq(wallet.txCount(), 1);
        DAOMultiSigWallet.Tx memory transac = wallet.getTransaction(0);
        assertEq(transac.to, recipient);
        assertEq(transac.value, 1 ether);
        assertEq(transac.executed, false);
        assertEq(transac.confirmations, 0);
        assertEq(transac.revocations, 0);
    }

    function testSubmitTransactionFailsFromNonTrusted() public {
        vm.prank(nonOwner);
        vm.expectRevert(DAOMultiSigWallet.NotTrusted.selector);
        wallet.submit(recipient, 1 ether, "");
    }

    function testConfirmTransaction() public {
        // Submit transaction
        vm.prank(owner1);
        wallet.submit(recipient, 1 ether, "");

        // First confirmation
        vm.prank(owner1);
        vm.expectEmit(true, true, false, true);
        emit TxConfirmed(owner1, 0, 1);
        wallet.confirm(0);

        assertTrue(wallet.confirmed(0, owner1));
        assertEq(recipient.balance, 0); // Not executed yet

        // Second confirmation should trigger quorum reached but NOT auto-execute
        vm.prank(owner2);
        vm.expectEmit(true, true, false, true);
        emit TxConfirmed(owner2, 0, 2);
        vm.expectEmit(true, false, false, false);
        emit TxQuorumReached(0);
        wallet.confirm(0);

        // Transaction should still not be executed automatically
        assertEq(recipient.balance, 0);
        assertEq(address(wallet).balance, 10 ether);
    }

    function testConfirmTransactionFailsFromNonTrusted() public {
        vm.prank(owner1);
        wallet.submit(recipient, 1 ether, "");

        vm.prank(nonOwner);
        vm.expectRevert(DAOMultiSigWallet.NotTrusted.selector);
        wallet.confirm(0);
    }

    function testConfirmTransactionFailsWhenAlreadyConfirmed() public {
        vm.prank(owner1);
        wallet.submit(recipient, 1 ether, "");

        vm.prank(owner1);
        wallet.confirm(0);

        vm.prank(owner1);
        vm.expectRevert(DAOMultiSigWallet.AlreadyConfirmed.selector);
        wallet.confirm(0);
    }

    function testExecuteTransaction() public {
        vm.prank(owner1);
        wallet.submit(recipient, 1 ether, "");

        // Get enough confirmations
        vm.prank(owner1);
        wallet.confirm(0);
        vm.prank(owner2);
        wallet.confirm(0);

        // Now execute manually
        vm.prank(owner3);
        vm.expectEmit(true, true, false, true);
        emit TransactionExecuted(0, recipient, 1 ether);
        wallet.execute(0);

        // Check execution was successful
        assertEq(recipient.balance, 1 ether);
        assertEq(address(wallet).balance, 9 ether);
    }

    function testExecuteTransactionFailsWhenInsufficientFunds() public {
        vm.prank(owner1);
        wallet.submit(recipient, 20 ether, ""); // More than wallet balance

        vm.prank(owner1);
        wallet.confirm(0);
        vm.prank(owner2);
        wallet.confirm(0);

        // Execute should fail due to insufficient funds
        vm.prank(owner3);
        vm.expectRevert(DAOMultiSigWallet.TransactionExecutionFailed.selector);
        wallet.execute(0);
    }

    function testExecuteTransactionFailsWhenNotConfirmed() public {
        vm.prank(owner1);
        wallet.submit(recipient, 1 ether, "");

        vm.prank(owner1);
        vm.expectRevert(DAOMultiSigWallet.QuorumNotReached.selector);
        wallet.execute(0);
    }

    // Transaction Revocation Tests
    function testRevokeTransaction() public {
        // Submit transaction
        vm.prank(owner1);
        wallet.submit(recipient, 1 ether, "");

        // Revoke transaction (need quorumSize / 2 = 1 revocation)
        vm.prank(owner1);
        vm.expectEmit(true, true, false, false);
        emit TransactionRevoked(0, owner1);
        wallet.revokeTransaction(0);

        assertTrue(wallet.revoked(0, owner1));

        // Try to confirm revoked transaction should fail
        vm.prank(owner2);
        vm.expectRevert();
        wallet.confirm(0);
    }

    function testRevokeTransactionFailsWhenAlreadyExecuted() public {
        vm.prank(owner1);
        wallet.submit(recipient, 1 ether, "");

        // Execute transaction first
        vm.prank(owner1);
        wallet.confirm(0);
        vm.prank(owner2);
        wallet.confirm(0);
        vm.prank(owner3);
        wallet.execute(0);

        // Try to revoke executed transaction
        vm.prank(owner3);
        vm.expectRevert(DAOMultiSigWallet.TransactionAlreadyExecuted.selector);
        wallet.revokeTransaction(0);
    }

    function testRevokeTransactionFailsFromNonTrusted() public {
        vm.prank(owner1);
        wallet.submit(recipient, 1 ether, "");

        vm.prank(nonOwner);
        vm.expectRevert(DAOMultiSigWallet.NotTrusted.selector);
        wallet.revokeTransaction(0);
    }

    function testRevokeTransactionFailsWhenAlreadyRevokedBySameOwner() public {
        vm.prank(owner1);
        wallet.submit(recipient, 1 ether, "");

        vm.prank(owner1);
        wallet.revokeTransaction(0);

        vm.prank(owner1);
        vm.expectRevert(DAOMultiSigWallet.AlreadyRevoked.selector);
        wallet.revokeTransaction(0);
    }

    function testConfirmTransactionFailsWhenAlreadyRevoked() public {
        vm.prank(owner1);
        wallet.submit(recipient, 1 ether, "");

        // First revoke the transaction
        vm.prank(owner1);
        wallet.revokeTransaction(0);

        // Try to confirm revoked transaction should fail
        vm.prank(owner2);
        vm.expectRevert(DAOMultiSigWallet.AlreadyRevoked.selector);
        wallet.confirm(0);
    }

    // View Function Tests
    function testGetTrustedOwnersFromList() public {
        address[] memory ownerList = new address[](4);
        ownerList[0] = owner1;
        ownerList[1] = owner2;
        ownerList[2] = owner3;
        ownerList[3] = newOwner;

        // Submit newOwner but don't make trusted
        vm.prank(owner1);
        wallet.submitOwner(newOwner);

        address[] memory trustedOwners = wallet.getTrustedOwnersFromList(
            ownerList
        );
        assertEq(trustedOwners.length, 3); // Only original owners are trusted

        // Make newOwner trusted
        vm.prank(owner2);
        wallet.supportOwner(newOwner);

        trustedOwners = wallet.getTrustedOwnersFromList(ownerList);
        assertEq(trustedOwners.length, 4); // Now includes newOwner
    }

    function testIsTrustedOwner() public {
        assertTrue(wallet.isTrustedOwner(owner1));
        assertTrue(wallet.isTrustedOwner(owner2));
        assertTrue(wallet.isTrustedOwner(owner3));
        assertFalse(wallet.isTrustedOwner(nonOwner));

        // Submit but don't support newOwner
        vm.prank(owner1);
        wallet.submitOwner(newOwner);
        assertFalse(wallet.isTrustedOwner(newOwner));

        // Support newOwner
        vm.prank(owner2);
        wallet.supportOwner(newOwner);
        assertTrue(wallet.isTrustedOwner(newOwner));
    }

    function testGetOwnerInfo() public {
        // Test owner1 using individual functions
        assertTrue(wallet.owners(owner1));
        assertEq(wallet.ownerTrustCount(owner1), 3); // All initial owners trust each other
        assertTrue(wallet.isTrustedOwner(owner1));
        assertEq(wallet.trustValue(owner1), 1); // 3 - 2 = 1

        // Test nonOwner using individual functions
        assertFalse(wallet.owners(nonOwner));
        assertEq(wallet.ownerTrustCount(nonOwner), 0);
        assertFalse(wallet.isTrustedOwner(nonOwner));

        // trustValue should revert for non-owners
        vm.expectRevert(DAOMultiSigWallet.OwnerNotFound.selector);
        wallet.trustValue(nonOwner);
    }

    // Edge case tests
    function testTransactionOutOfBounds() public {
        vm.prank(owner1);
        vm.expectRevert(DAOMultiSigWallet.TransactionNotFound.selector);
        wallet.confirm(999); // Non-existent transaction

        vm.prank(owner1);
        vm.expectRevert(DAOMultiSigWallet.TransactionNotFound.selector);
        wallet.revokeTransaction(999); // Non-existent transaction

        vm.expectRevert(DAOMultiSigWallet.TransactionNotFound.selector);
        wallet.getTransaction(999);
    }

    function testTrustValueCalculations() public {
        // Submit newOwner (starts with 1 supporter, trust value = 1-2 = -1)
        vm.prank(owner1);
        wallet.submitOwner(newOwner);

        vm.prank(newOwner);
        vm.expectRevert(DAOMultiSigWallet.NotTrusted.selector); // Because trustValue < 0
        wallet.submit(recipient, 1 ether, "");

        // Add support to make trusted
        vm.prank(owner2);
        wallet.supportOwner(newOwner);

        // Now should work
        vm.prank(newOwner);
        wallet.submit(recipient, 1 ether, "");
    }

    // Receive Function Test
    function testReceiveEther() public {
        uint256 initialBalance = address(wallet).balance;

        vm.deal(owner1, 5 ether);
        vm.prank(owner1);
        (bool success, ) = address(wallet).call{value: 2 ether}("");

        assertTrue(success);
        assertEq(address(wallet).balance, initialBalance + 2 ether);
    }

    // Test with empty data
    function testSubmitTransactionWithData() public {
        bytes memory data = abi.encodeWithSignature("someFunction()");

        vm.prank(owner1);
        wallet.submit(recipient, 1 ether, data);

        DAOMultiSigWallet.Tx memory transac = wallet.getTransaction(0);
        assertEq(transac.data, data);
    }
}
