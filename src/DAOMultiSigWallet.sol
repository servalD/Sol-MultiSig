// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title MultiSigEOAWallet
 * @dev A multi-signature wallet that only accepts EOA (Externally Owned Account) owners
 * @notice This contract allows multiple owners to manage funds with a trust-based system requiring confirmations for transactions
 * @dev TODO: Determine the max recursive check depth for the trustedBy chain. (it will determine the max owners length and/or the max quorum size to prevent stack overflow)
 */
contract DAOMultiSigWallet {
    //////////////////////////// GENERAL VARIABLES ////////////////////////////////////
    /// @notice The minimum number of confirmations required to execute an operation (add/revoke owner, submit transaction)
    uint public quorum;

    /// @notice Number of owner
    uint public ownerCount;

    /// @notice Total number of trusted owners
    uint public trustedCount;

    /// @notice Number of transaction
    uint public txCount;

    //* OWNER *//

    /// @notice Mapping from address to owner status
    mapping(address => bool) public owners;

    /// @notice Mapping from owner address to trusted status via supporter address
    mapping(address => mapping(address => bool)) public ownerTrustedBy;

    /// @notice Mapping from owner address to trust count
    mapping(address => uint) public ownerTrustCount;

    //* TRANSACTION *//

    /**
     * @dev Structure representing a transaction
     * @param to The destination address for the transaction
     * @param value The amount of Ether to send
     * @param data Optional data for the transaction
     * @param executed Whether the transaction has been executed
     * @param confirmations The number of confirmations received
     * @param revocations The number of revocations received
     */
    struct Tx {
        address to;
        uint value;
        bytes data;
        bool executed;
        uint confirmations;
        uint revocations;
    }

    /// @notice Mapping from transaction index to confirmation status by owner
    mapping(uint => mapping(address => bool)) public confirmed;

    /// @notice Mapping from transaction index to revocation status by owner
    mapping(uint => mapping(address => bool)) public revoked;

    /// @notice Mapping from transaction index to transaction
    mapping(uint => Tx) public transactions;

    //////////////////////////// EVENTS ////////////////////////////////////

    event OwnerTrustedBy(address indexed owner, address supporter);
    event OwnerUnTrustedBy(address indexed owner, address supporter);
    event OwnerSubmitted(address indexed newOwner);

    /// @notice Emitted when an owner reaches the trust threshold
    /// @param owner The address of the confirmed owner
    event OwnerConfirmed(address indexed owner);

    /// @notice Emitted when an owner falls below the trust threshold
    /// @param owner The address of the revoked owner
    event OwnerRevoked(address indexed owner);

    event TransactionRevoked(uint indexed txIndex, address indexed revoker);

    event Deposit(address indexed sender, uint amount, uint balance);

    event TransactionExecuted(
        uint indexed txIndex,
        address indexed to,
        uint value
    );

    event TxConfirmed(
        address indexed confirmer,
        uint indexed txIndex,
        uint confirmations
    );

    event TxQuorumReached(uint indexed txIndex);

    event TransactionSubmitted(
        uint indexed txIndex,
        address indexed to,
        uint value
    );

    //////////////////////////// ERRORS ////////////////////////////////////

    error AlreadyOwner();
    error OwnerNotFound();
    error NotTrusted();
    error NotEnoughOwners();
    /// @dev Thrown when removing support would result in insufficient trusted owners
    error InsufficientTrustedOwners();
    /// @dev Thrown when an owner is not supported by the caller
    error NotSupporter();
    error ZeroAddress();

    error QuorumTooLow();
    error QuorumTooHigh();
    error QuorumNotReached();

    error TransactionNotFound();
    error TransactionAlreadyExecuted();
    error TransactionRevokedErr(uint txIndex, address revoker);

    /// @dev Thrown when an owner has already confirmed a transaction
    error AlreadyConfirmed();
    error AlreadyRevoked();
    /// @dev Thrown when transaction execution fails
    error TransactionExecutionFailed();

    ////////////////////////// MODIFIERS ////////////////////////////////////

    /// @notice Modifier to restrict access to trusted addresses only
    modifier onlyTrusted() {
        if (!owners[msg.sender]) {
            revert NotTrusted();
        }
        require(trustValue(msg.sender) >= 0, NotTrusted());
        _;
    }

    modifier existingTx(uint txIndex) {
        require(txIndex < txCount, TransactionNotFound());
        _;
    }

    modifier notRevokedTx(uint txIndex) {
        require(!isTxRevoked(txIndex), AlreadyRevoked());
        _;
    }

    modifier ConfirmedTx(uint txIndex) {
        require(isTxConfirmed(txIndex), QuorumNotReached());
        _;
    }

    //////////////////////////// CONSTRUCTOR ////////////////////////////////////

    /**
     * @notice Constructor to initialize the wallet with initial owners and quorum size
     * @param _owners Array of initial owner addresses (must be EOAs)
     * @param _quorumSize Minimum number of confirmations required for transactions
     * @dev Requires at least 3 owners and quorum size between 2 and total owners
     */
    constructor(address[] memory _owners, uint _quorumSize) {
        require(_owners.length >= 3, NotEnoughOwners());
        require(_quorumSize >= 2, QuorumTooLow());
        require(_quorumSize <= _owners.length, QuorumTooHigh());
        for (uint i = 0; i < _owners.length; i++) {
            addOwner(_owners[i], _owners);
        }
        quorum = _quorumSize;
        trustedCount = _owners.length;
    }

    //////////////////////////// FUNCTIONS ////////////////////////////////////

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
        require(owners[newOwner], OwnerNotFound());
        require(
            !ownerTrustedBy[newOwner][msg.sender],
            "Already supporting this owner"
        );

        // Check if owner was untrusted before this support
        bool wasUntrusted = trustValue(newOwner) < 0;

        ownerTrustedBy[newOwner][msg.sender] = true;
        ownerTrustCount[newOwner]++;

        emit OwnerTrustedBy(newOwner, msg.sender);

        // If owner becomes trusted for the first time
        if (wasUntrusted && trustValue(newOwner) >= 0) {
            trustedCount++;
            emit OwnerConfirmed(newOwner);
        }
    }

    /**
     * @notice Remove support for an owner
     * @param ownerToUnSupport The address of the owner to stop supporting
     * @dev Removes caller from the trustedBy list of the specified owner
     * @dev Ensures at least 3 trusted owners remain and quorum can still be met
     */
    function unSupportOwner(address ownerToUnSupport) external onlyTrusted {
        require(owners[ownerToUnSupport], OwnerNotFound());
        require(ownerTrustedBy[ownerToUnSupport][msg.sender], NotSupporter());

        // Check if owner was trusted before removing support
        bool wasTrusted = trustValue(ownerToUnSupport) >= 0;

        ownerTrustedBy[ownerToUnSupport][msg.sender] = false;
        ownerTrustCount[ownerToUnSupport]--;

        // Check if this owner will become untrusted after removing support
        bool willBecomeUntrusted = trustValue(ownerToUnSupport) < 0;

        if (wasTrusted && willBecomeUntrusted) {
            trustedCount--;
            if (trustedCount < quorum) {
                quorum--;
            }
            // Ensure we maintain at least 3 trusted owners
            require(trustedCount >= 3, InsufficientTrustedOwners());
        }

        emit OwnerUnTrustedBy(ownerToUnSupport, msg.sender);
        if (wasTrusted && willBecomeUntrusted)
            emit OwnerRevoked(ownerToUnSupport);
    }

    /**
     * @notice Submit a new transaction for execution
     * @param to The destination address
     * @param value The amount of Ether to send
     * @param data Optional data for the transaction
     * @dev Only trusted addresses can submit transactions
     */
    function submit(
        address to,
        uint value,
        bytes memory data
    ) external onlyTrusted {
        transactions[txCount] = Tx(to, value, data, false, 0, 0);
        emit TransactionSubmitted(txCount, to, value);
        txCount++;
    }

    /**
     * @notice Confirm a transaction
     * @param txIndex The index of the transaction to confirm
     * @dev Automatically executes if quorum is reached
     */
    function confirm(
        uint txIndex
    ) external onlyTrusted existingTx(txIndex) notRevokedTx(txIndex) {
        require(!confirmed[txIndex][msg.sender], AlreadyConfirmed());
        require(!transactions[txIndex].executed, TransactionAlreadyExecuted());
        require(
            !revoked[txIndex][msg.sender],
            TransactionRevokedErr(txIndex, msg.sender)
        );

        confirmed[txIndex][msg.sender] = true;
        transactions[txIndex].confirmations++;

        emit TxConfirmed(
            msg.sender,
            txIndex,
            transactions[txIndex].confirmations
        );

        if (transactions[txIndex].confirmations >= quorum) {
            emit TxQuorumReached(txIndex);
        }
    }

    /**
     * @notice Revoke a transaction
     * @param txIndex The index of the transaction to revoke
     * @dev Requires (quorum / 2) revocations to revoke a transaction
     */
    function revokeTransaction(
        uint txIndex
    ) external onlyTrusted existingTx(txIndex) {
        require(!transactions[txIndex].executed, TransactionAlreadyExecuted());
        require(!isTxRevoked(txIndex), AlreadyRevoked());
        require(!confirmed[txIndex][msg.sender], AlreadyConfirmed());
        require(!revoked[txIndex][msg.sender], AlreadyRevoked());

        revoked[txIndex][msg.sender] = true;
        transactions[txIndex].revocations++;

        if (isTxRevoked(txIndex)) {
            emit TransactionRevoked(txIndex, msg.sender);
        }
    }

    /**
     * @dev Execute a confirmed transaction
     * @param txIndex The index of the transaction to execute
     */
    function execute(
        uint txIndex
    )
        external
        onlyTrusted
        existingTx(txIndex)
        notRevokedTx(txIndex)
        ConfirmedTx(txIndex)
    {
        Tx storage transaction = transactions[txIndex];
        require(!transaction.executed, TransactionAlreadyExecuted());

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
        require(newOwner != address(0), ZeroAddress());
        require(!owners[newOwner], AlreadyOwner());

        owners[newOwner] = true;
        ownerTrustCount[newOwner] = trustedBy.length;

        for (uint i = 0; i < trustedBy.length; i++) {
            ownerTrustedBy[newOwner][trustedBy[i]] = true;
        }

        ownerCount++;
    }

    /**
     * @dev Check if an address is an owner
     * @param account The address to check
     * @return bool True if the address is an owner
     */
    function isOwner(address account) internal view returns (bool) {
        return owners[account];
    }

    /**
     * @dev Check if a transaction is revoked (if the quorum change, a Tx can be executed in the future) (if the trust value of the owner changes, I should update this)
     * @param txIndex The index of the transaction to check
     * @return bool True if the transaction has been revoked
     */
    function isTxRevoked(uint txIndex) internal view returns (bool) {
        return transactions[txIndex].revocations >= (quorum / 2);
    }

    /**
     * @dev Check if a transaction is confirmed
     * @param txIndex The index of the transaction to check
     * @return bool True if the transaction has enough confirmations
     */
    function isTxConfirmed(uint txIndex) internal view returns (bool) {
        return transactions[txIndex].confirmations >= quorum;
    }

    /**
     * @dev Calculate trust value for an address
     * @param account The address to check
     * @return int Trust value (trustedBy count - quorum size)
     */
    function trustValue(address account) public view returns (int) {
        require(owners[account], OwnerNotFound());
        return int(ownerTrustCount[account]) - int(quorum);
    }

    /**
     * @dev Get the index of an owner (not applicable without array)
     * @param account The owner address
     * @return uint Always returns 0 as we don't use indices anymore
     */
    function ownerIndex(address account) external view returns (uint) {
        require(owners[account], OwnerNotFound());
        return 0; // No longer meaningful without array
    }

    /**
     * @notice Get trusted status for a list of owners
     * @param ownerList Array of owner addresses to check
     * @return address[] Array of trusted owner addresses from the input list
     */
    function getTrustedOwnersFromList(
        address[] calldata ownerList
    ) external view returns (address[] memory) {
        uint trustedCountInList = 0;

        // First pass: count trusted owners
        for (uint i = 0; i < ownerList.length; i++) {
            if (owners[ownerList[i]] && trustValue(ownerList[i]) >= 0) {
                trustedCountInList++;
            }
        }

        // Second pass: populate result array
        address[] memory trustedOwners = new address[](trustedCountInList);
        uint index = 0;
        for (uint i = 0; i < ownerList.length; i++) {
            if (owners[ownerList[i]] && trustValue(ownerList[i]) >= 0) {
                trustedOwners[index] = ownerList[i];
                index++;
            }
        }

        return trustedOwners;
    }

    /**
     * @notice Check if an address is a trusted owner
     * @param account The address to check
     * @return bool True if the address is a trusted owner
     */
    function isTrustedOwner(address account) external view returns (bool) {
        return owners[account] && trustValue(account) >= 0;
    }

    /**
     * @notice Check if a specific owner has confirmed a transaction
     * @param txIndex The transaction index
     * @param owner The owner address
     * @return bool True if the owner has confirmed
     */
    function hasConfirmed(
        uint txIndex,
        address owner
    ) external view returns (bool) {
        return confirmed[txIndex][owner];
    }

    /**
     * @notice Check if a specific owner has revoked a transaction
     * @param txIndex The transaction index
     * @param owner The owner address
     * @return bool True if the owner has revoked
     */
    function hasRevoked(
        uint txIndex,
        address owner
    ) external view returns (bool) {
        return revoked[txIndex][owner];
    }

    function getTransaction(
        uint txIndex
    ) external view existingTx(txIndex) returns (Tx memory) {
        return transactions[txIndex];
    }
}
