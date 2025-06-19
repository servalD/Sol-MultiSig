// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title MultiSigEOAWallet
 * @dev A multi-signature wallet that only accepts EOA (Externally Owned Account) owners
 * @notice This contract allows multiple owners to manage funds with a trust-based system requiring confirmations for transactions
 * @dev TODO: Determine the max recursive check depth for the trustedBy chain. (it will determine the max owners length and/or the max quorum size to prevent stack overflow)
 */
contract MultiSigEOAWallet {
    /// @notice The minimum number of confirmations required to execute a transaction
    int public quorumSize;

    /**
     * @dev Structure representing an owner of the wallet
     * @param owner The address of the owner
     * @param trustedBy Array of addresses that trust this owner
     * @param trustedChainConstancy Flag to verify that all trustedBy addresses are themselves trusted
     */
    struct Owner {
        address owner;
        address[] trustedBy;
        bool trustedChainConstancy;
    }

    /**
     * @dev Structure representing a transaction
     * @param to The destination address for the transaction
     * @param value The amount of Ether to send
     * @param executed Whether the transaction has been executed
     * @param confirmations The number of confirmations received
     * @param revoked Whether the transaction has been revoked
     * @param revocations The number of revocations received
     */
    struct Tx {
        address to;
        uint value;
        bytes data; // Optional data for the transaction
        bool executed;
        uint confirmations;
        bool revoked;
        uint revocations;
    }

    /// @notice Mapping to track which owners have confirmed which transactions
    mapping(uint => mapping(address => bool)) public confirmed;

    /// @notice Mapping to track which owners have revoked which transactions
    mapping(uint => mapping(address => bool)) public revoked;

    /// @notice mapping of all owners
    mapping(uint => Owner) public owners;

    /// @notice Number of ownerz
    uint public ownerCount;

    /// @notice Array of all transactions
    Tx[] public transactions;

    /// @notice Emitted when an owner is trusted by another address
    /// @param owner The owner being trusted
    /// @param supporter The address providing trust
    event OwnerTrustedBy(address indexed owner, address supporter);

    /// @notice Emitted when an owner loses trust from another address
    /// @param owner The owner losing trust
    /// @param supporter The address removing trust
    event OwnerUnTrustedBy(address indexed owner, address supporter);

    /// @notice Emitted when a new owner is submitted for consideration
    /// @param newOwner The address of the proposed new owner
    event OwnerSubmitted(address indexed newOwner);

    /// @notice Emitted when an owner reaches the trust threshold
    /// @param owner The address of the confirmed owner
    event OwnerConfirmed(address indexed owner);

    /// @notice Emitted when an owner falls below the trust threshold
    /// @param owner The address of the revoked owner
    event OwnerRevoked(address indexed owner);

    /// @notice Emitted when a transaction is revoked
    /// @param txIndex The index of the revoked transaction
    /// @param revoker The address that revoked the transaction
    event TransactionRevoked(uint indexed txIndex, address indexed revoker);

    /// @notice Emitted when Ether is deposited into the wallet
    /// @param sender The address that sent the Ether
    /// @param amount The amount of Ether sent
    /// @param balance The new balance of the wallet after the deposit
    event Deposit(address indexed sender, uint amount, uint balance);

    /// @notice Emitted when a transaction is executed
    /// @param txIndex The index of the executed transaction
    /// @param to The destination address of the transaction
    /// @param value The amount of Ether sent in the transaction
    event TransactionExecuted(uint indexed txIndex, address indexed to, uint value);

    /// @dev Thrown when there are not enough owners
    error NotEnoughOwners();

    /// @dev Thrown when there are not enough confirmations
    error NotEnoughConfirmations();

    /// @dev Thrown when trying to execute an already executed transaction
    error TransactionAlreadyExecuted();

    /// @dev Thrown when referencing a non-existent transaction
    error TransactionNotFound();

    /// @dev Thrown when an address is not trusted
    error NotTrusted();

    /// @dev Thrown when caller is not an owner
    error NotOwner();

    /// @dev Thrown when an invalid address is provided
    error InvalidAddress();

    /// @dev Thrown when trying to add an address that is already an owner
    error AlreadyOwner();

    /// @dev Thrown when referencing a non-existent owner
    error OwnerNotFound();

    /// @dev Thrown when a transaction is revoked
    error TransactionRevokedErr(uint txIndex, address revoker);

    /// @dev Thrown when removing support would result in insufficient trusted owners
    error InsufficientTrustedOwners();

    /// @dev Thrown when an owner has already confirmed a transaction
    error AlreadyConfirmed();

    /// @dev Thrown when an owner has already revoked a transaction
    error AlreadyRevoked();

    /// @dev Thrown when an owner is not supported by the caller
    error NotSupportedByOwner();

    /// @dev Thrown when transaction execution fails
    error TransactionExecutionFailed();

    /// @notice Modifier to restrict access to owners only
    modifier onlyOwner() {
        require(isOwner(msg.sender), NotOwner());
        _;
    }

    /// @notice Modifier to restrict access to trusted addresses only
    modifier onlyTrusted() {
        require(trustValue(msg.sender) >= 0, NotTrusted());
        _;
    }

    /**
     * @notice Constructor to initialize the wallet with initial owners and quorum size
     * @param _owners Array of initial owner addresses (must be EOAs)
     * @param _quorumSize Minimum number of confirmations required for transactions
     * @dev Requires at least 3 owners and quorum size between 2 and total owners
     */
    constructor(address[] memory _owners, int _quorumSize) {
        require(_owners.length >= 3, NotEnoughOwners());
        require(
            _quorumSize >= 2 && _quorumSize <= int(_owners.length),
            NotEnoughConfirmations()
        );
        for (uint i = 0; i < _owners.length; i++) {
            addOwner(_owners[i], _owners);
        }
        quorumSize = _quorumSize;
    }

    /// @notice Allows the contract to receive Ether
    receive() external payable {
        emit Deposit(msg.sender, msg.value, address(this).balance);
    }

    /**
     * @notice Submit a new owner for consideration
     * @param newOwner The address of the proposed new owner
     * @dev Only trusted addresses can submit new owners
     */
    function submitOwner(address newOwner) external onlyTrusted {
        address[] memory trustedBy = new address[](1);
        trustedBy[0] = msg.sender; // Add the submitter as a trustedBy
        addOwner(newOwner, trustedBy);
        emit OwnerSubmitted(newOwner);
    }

    /**
     * @notice Support an existing owner proposal
     * @param newOwner The address of the owner to support
     * @dev Adds caller to the trustedBy list of the specified owner
     */
    function supportOwner(address newOwner) external onlyTrusted {
        uint i = ownerIndex(newOwner); // Check if the owner exists
        owners[i].trustedBy.push(msg.sender);
        if (trustValue(i) == 0) emit OwnerConfirmed(newOwner);
        emit OwnerTrustedBy(newOwner, msg.sender);
    }

    /**
     * @notice Remove support for an owner
     * @param ownerToUnSupport The address of the owner to stop supporting
     * @dev Removes caller from the trustedBy list of the specified owner
     * @dev Ensures at least 3 trusted owners remain and quorum can still be met
     */
    function unSupportOwner(address ownerToUnSupport) external onlyTrusted {
        uint i = ownerIndex(ownerToUnSupport); // Check if the owner exists
        bool found = popArrayElement(owners[i].trustedBy, msg.sender);
        require(found, NotSupportedByOwner());

        // Check if this owner will become untrusted after removing support
        bool willBecomeUntrusted = (trustValue(i) == -1);

        if (willBecomeUntrusted) {
            // Count current trusted owners
            uint trustedCount = 0;
            for (uint j = 0; j < ownerCount; j++) {
                if (j == i) {
                    // Skip the owner being unsupported as they will become untrusted
                    continue;
                }
                if (trustValue(j) >= 0) {
                    trustedCount++;
                }
            }
            if (int(trustedCount) < quorumSize - 1) {
                quorumSize -= 1;
            }
            // Ensure we maintain at least 3 trusted owners and can meet quorum
            require(trustedCount >= 3, InsufficientTrustedOwners());
        }

        if (willBecomeUntrusted) emit OwnerRevoked(ownerToUnSupport);
        emit OwnerUnTrustedBy(ownerToUnSupport, msg.sender);
    }

    /**
     * @notice Submit a new transaction for execution
     * @param to The destination address
     * @param value The amount of Ether to send
     * @dev Only trusted addresses can submit transactions
     */
    function submit(
        address to,
        uint value,
        bytes memory data
    ) external onlyTrusted {
        transactions.push(Tx(to, value, data, false, 0, false, 0));
    }

    /**
     * @notice Confirm a transaction
     * @param txIndex The index of the transaction to confirm
     * @dev Automatically executes if quorum is reached
     */
    function confirm(uint txIndex) external onlyTrusted {
        require(txIndex < transactions.length, TransactionNotFound());
        require(
            !transactions[txIndex].revoked,
            TransactionRevokedErr(txIndex, msg.sender)
        );
        require(!confirmed[txIndex][msg.sender], AlreadyConfirmed());

        confirmed[txIndex][msg.sender] = true;
        transactions[txIndex].confirmations++;

        if (int(transactions[txIndex].confirmations) >= quorumSize) {
            execute(txIndex);
        }
    }

    /**
     * @notice Revoke a transaction
     * @param txIndex The index of the transaction to revoke
     * @dev Requires (quorumSize / 2) + 1 revocations to revoke a transaction
     */
    function revokeTransaction(uint txIndex) external onlyTrusted {
        require(txIndex < transactions.length, TransactionNotFound());
        require(!transactions[txIndex].executed, TransactionAlreadyExecuted());
        require(
            !transactions[txIndex].revoked,
            TransactionRevokedErr(txIndex, msg.sender)
        );
        require(!revoked[txIndex][msg.sender], AlreadyRevoked());

        revoked[txIndex][msg.sender] = true;
        transactions[txIndex].revocations++;

        if (int(transactions[txIndex].revocations) >= (quorumSize / 2) + 1) {
            transactions[txIndex].revoked = true;
            emit TransactionRevoked(txIndex, msg.sender);
        }
    }

    /**
     * @dev Internal function to execute a confirmed transaction
     * @param txIndex The index of the transaction to execute
     */
    function execute(uint txIndex) internal {
        Tx storage transaction = transactions[txIndex];
        require(!transaction.executed, TransactionAlreadyExecuted());
        require(
            !transaction.revoked,
            TransactionRevokedErr(txIndex, msg.sender)
        );

        transaction.executed = true;
        (bool ok, ) = transaction.to.call{value: transaction.value}(
            transaction.data
        );
        require(ok, TransactionExecutionFailed());

        emit TransactionExecuted(txIndex, transaction.to, transaction.value);
    }

    /**
     * @dev Internal function to add a new owner
     * @param newOwner The address of the new owner
     * @param trustedBy Array of addresses that initially trust this owner
     */
    function addOwner(address newOwner, address[] memory trustedBy) internal {
        require(newOwner != address(0), InvalidAddress());
        require(!isOwner(newOwner), AlreadyOwner());

        owners[ownerCount] = Owner(
            newOwner,
            trustedBy,
            int(trustedBy.length) >= quorumSize
        );
        ownerCount++;
    }

    /**
     * @dev Check if an address is an owner
     * @param account The address to check
     * @return bool True if the address is an owner
     */
    function isOwner(address account) internal view returns (bool) {
        for (uint i = 0; i < ownerCount; i++) {
            if (owners[i].owner == account) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Calculate trust value for an address
     * @param account The address to check
     * @return int Trust value (trustedBy count - quorum size)
     */
    function trustValue(address account) internal view returns (int) {
        for (uint i = 0; i < ownerCount; i++) {
            if (owners[i].owner == account) {
                return int(owners[i].trustedBy.length) - quorumSize;
            }
        }
        revert OwnerNotFound();
    }

    /**
     * @dev Calculate trust value for an owner by index
     * @param _ownerIndex The index of the owner
     * @return int Trust value (trustedBy count - quorum size)
     */
    function trustValue(uint _ownerIndex) internal view returns (int) {
        if (_ownerIndex < ownerCount) {
            return int(owners[_ownerIndex].trustedBy.length) - quorumSize;
        }
        revert OwnerNotFound();
    }

    /**
     * @dev Get the index of an owner
     * @param account The owner address
     * @return uint The index of the owner in the owners mapping
     */
    function ownerIndex(address account) internal view returns (uint) {
        for (uint i = 0; i < ownerCount; i++) {
            if (owners[i].owner == account) {
                return i;
            }
        }
        revert OwnerNotFound();
    }

    /**
     * @dev Remove an element from an array
     * @param array The storage array to modify
     * @param element The element to remove
     * @return bool True if element was found and removed
     */
    function popArrayElement(
        address[] storage array,
        address element
    ) internal returns (bool) {
        bool found = false;
        for (uint i = 0; i < array.length; i++) {
            if (array[i] == element) {
                found = true;
            } else if (found) {
                array[i - 1] = array[i]; // Replace with the last element
            }
        }
        if (found) {
            array.pop(); // Remove the last element
            return true; // Element found and removed
        } else {
            return false; // Element not found
        }
    }

    /**
     * @notice Get all owners
     * @return Owner[] Array of all owners with their trust information
     */
    function getOwners() external view returns (Owner[] memory) {
        Owner[] memory allOwners = new Owner[](ownerCount);
        for (uint i = 0; i < ownerCount; i++) {
            allOwners[i] = owners[i];
        }
        return allOwners;
    }

    /**
     * @notice Get all trusted owners (those with trust value >= 0)
     * @return address[] Array of trusted owner addresses
     */
    function getTrustedOwners() external view returns (address[] memory) {
        // First count trusted owners
        uint trustedCount = 0;
        for (uint i = 0; i < ownerCount; i++) {
            if (trustValue(i) >= 0) {
                trustedCount++;
            }
        }

        // Create array with correct size
        address[] memory trustedOwners = new address[](trustedCount);
        uint count = 0;
        for (uint i = 0; i < ownerCount; i++) {
            if (trustValue(i) >= 0) {
                trustedOwners[count] = owners[i].owner;
                count++;
            }
        }

        return trustedOwners;
    }
}
