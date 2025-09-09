// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// Define the interface for PasarEscrow to allow PasarDispute to call its functions.
// This interface must match the public functions of PasarEscrow that PasarDispute needs to interact with.
interface IPasarEscrow {
    /// @notice Refunds funds to the buyer for a given order.
    /// @param _orderId The unique identifier of the order.
    function refundBuyer(bytes32 _orderId) external;

    /// @notice Releases funds to a crypto seller's address.
    /// @param _orderId The unique identifier of the order.
    /// @param _sellerCryptoAddress The crypto address of the seller.
    function releaseFundsToCryptoSeller(bytes32 _orderId, address _sellerCryptoAddress) external;

    /// @notice Releases funds to the platform's treasury for a fiat seller.
    /// @param _orderId The unique identifier of the order.
    /// @param _sellerIdHash The hash of the seller's internal ID for backend reconciliation.
    function releaseFundsToPlatformForFiatSeller(bytes32 _orderId, bytes32 _sellerIdHash) external;

    // Add other functions from PasarEscrow that might be needed, e.g., for split funds.
    // function splitFunds(bytes32 _orderId, uint256 buyerShare, uint256 sellerShare) external;
}

/// @title PasarDispute
/// @author Olujimi
/// @notice Manages the on-chain state and execution of dispute resolutions for the Pasar protocol.
/// @dev This contract is upgradeable via UUPS, includes access control, pausability, and reentrancy protection.
///      It records dispute details, allows authorized parties to submit final verdicts, and triggers
///      fund movements on the PasarEscrow contract based on these verdicts.
contract PasarDispute is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // ============================
    // Roles
    // ============================
    // These roles are defined within PasarDispute and managed by AccessManager.

    /// @notice Role for the trusted backend service responsible for submitting and executing dispute verdicts.
    bytes32 public constant DISPUTE_MANAGER_ROLE = keccak256("DISPUTE_MANAGER_ROLE");
    /// @notice Role for general platform services that might initiate disputes or query dispute status.
    bytes32 public constant PLATFORM_SERVICE_ROLE = keccak256("PLATFORM_SERVICE_ROLE");
    // DEFAULT_ADMIN_ROLE is inherited from AccessControlUpgradeable and is the highest authority for this contract.

    // ============================
    // Enums
    // ============================

    /// @notice Represents the current status of a dispute.
    enum DisputeStatus {
        Pending,  // Dispute initiated but not yet formally opened or processed.
        Open,     // Dispute is active and undergoing arbitration.
        Resolved, // A verdict has been submitted, but not yet executed.
        Closed    // The verdict has been executed, and the dispute is finalized.
    }

    /// @notice Represents the possible outcomes of a dispute verdict.
    enum VerdictType {
        None,                   // No verdict submitted yet.
        RefundBuyer,            // Funds should be entirely returned to the buyer.
        ReleaseToCryptoSeller,  // Funds should be entirely released to the crypto seller.
        ReleaseToFiatSeller,    // Funds should be entirely released to the platform for fiat seller payout.
        SplitFunds              // Funds should be split between buyer and seller (requires more details).
    }

    // ============================
    // Structs
    // ============================

    /// @notice Stores comprehensive details about an open or pending dispute.
    struct Dispute {
        bytes32 orderId;       // The unique ID of the order associated with this dispute.
        address buyer;         // The address of the buyer in the order.
        address seller;        // The address of the seller in the order.
        uint256 amount;        // The total amount of funds involved in the dispute.
        address token;         // The address of the ERC-20 token used for the transaction.
        uint256 initiatedAt;   // The timestamp when the dispute was initiated.
        DisputeStatus status;  // The current status of the dispute.
        bool exists;           // Flag to indicate if this dispute entry is active.
    }

    /// @notice Stores the final verdict details for a resolved dispute.
    struct Verdict {
        bytes32 disputeId;     // The ID of the dispute this verdict belongs to.
        VerdictType outcome;   // The type of outcome (e.g., RefundBuyer, ReleaseToSeller).
        uint256 resolvedAt;    // The timestamp when the verdict was submitted.
        bool exists;           // Flag to indicate if a verdict has been submitted for this dispute.
        // For SplitFunds, additional fields like buyerShare, sellerShare would be needed.
        // uint256 buyerShare;
        // uint256 sellerShare;
    }

    // ============================
    // State Variables
    // ============================

    /// @notice Address of the deployed AccessManager contract. Used to query roles.
    address public immutable ACCESS_MANAGER_ADDRESS;
    /// @notice Address of the deployed PasarEscrow contract. Used to trigger fund movements.
    address public pasarEscrowAddress;
    /// @notice Mapping from unique dispute IDs to their Dispute struct details.
    mapping(bytes32 => Dispute) public disputes;
    /// @notice Mapping from unique dispute IDs to their Verdict struct details.
    mapping(bytes32 => Verdict) public verdicts;
    /// @notice A dynamic array to keep track of all active dispute IDs for efficient iteration (e.g., for off-chain indexing).
    bytes32[] public activeDisputes;
    /// @notice Stores the address of the PasarAdmin contract, which is authorized to upgrade this contract.
    address public pasarAdminAddress;

    // ============================
    // Custom Errors
    // ============================

    /// @notice Thrown when a provided dispute ID does not correspond to an existing dispute.
    error InvalidDisputeId();
    /// @notice Thrown when an attempt is made to open a dispute that is already open.
    error DisputeAlreadyOpen();
    /// @notice Thrown when an action requires an open dispute, but the dispute is not in the 'Open' status.
    error DisputeNotOpen();
    /// @notice Thrown when a verdict is submitted for a dispute that already has a verdict.
    error VerdictAlreadySubmitted();
    /// @notice Thrown when an action requires a submitted verdict, but no verdict exists for the dispute.
    error VerdictNotSubmitted();
    /// @notice Thrown when an action requires a resolved dispute, but the dispute is not in the 'Resolved' status.
    error DisputeNotResolved();
    /// @notice Thrown when an unauthorized party attempts to initiate a dispute for an order they are not part of.
    error UnauthorizedDisputeInitiator();
    /// @notice Thrown when an unauthorized address attempts to submit a dispute verdict.
    error UnauthorizedVerdictSubmission();
    /// @notice Thrown when the PasarEscrow contract address is invalid or not set.
    error InvalidEscrowAddress();
    error InvalidAddress();
    error UnauthorizedOperation();


    // ============================
    // Events
    // ============================

    /// @notice Emitted when a new dispute is successfully opened.
    /// @param disputeId The unique ID of the opened dispute.
    /// @param orderId The ID of the order associated with the dispute.
    /// @param buyer The buyer's address.
    /// @param seller The seller's address.
    /// @param amount The amount in dispute.
    /// @param token The token address in dispute.
    event DisputeOpened(bytes32 indexed disputeId, bytes32 indexed orderId, address indexed buyer, address seller, uint256 amount, address token);
    /// @notice Emitted when a final verdict for a dispute is submitted on-chain.
    /// @param disputeId The unique ID of the dispute.
    /// @param outcome The type of verdict outcome.
    /// @param submitter The address that submitted the verdict (should be DISPUTE_MANAGER_ROLE).
    event VerdictSubmitted(bytes32 indexed disputeId, VerdictType outcome, address indexed submitter);
    /// @notice Emitted when a submitted verdict is successfully executed, leading to fund movements.
    /// @param disputeId The unique ID of the dispute.
    /// @param outcome The type of verdict outcome that was executed.
    /// @param executor The address that triggered the execution (should be DISPUTE_MANAGER_ROLE).
    event VerdictExecuted(bytes32 indexed disputeId, VerdictType outcome, address indexed executor);
    /// @notice Emitted when a dispute is formally closed after its verdict has been executed.
    /// @param disputeId The unique ID of the dispute.
    /// @param finalStatus The final status of the dispute (should be 'Closed').
    event DisputeClosed(bytes32 indexed disputeId, DisputeStatus finalStatus);

    // ============================
    // Initialization
    // ============================

    /// @notice Initializes the PasarDispute contract.
    /// @dev This function sets the immutable `ACCESS_MANAGER_ADDRESS`, the `pasarEscrowAddress`,
    ///      and the `pasarAdminAddress` for upgrade authorization. It also initializes all inherited
    ///      OpenZeppelin upgradeable contracts.
    /// @param _accessManagerAddress The address of the deployed AccessManager contract.
    /// @param _pasarEscrowAddress The address of the deployed PasarEscrow contract.
    /// @param _pasarAdminAddress The address of the PasarAdmin contract (Timelock) for upgrade authorization.
    function initialize(
        address _accessManagerAddress,
        address _pasarEscrowAddress,
        address _pasarAdminAddress
    ) public initializer {
        // Input Validation: Ensure critical addresses are not zero.
        if (_accessManagerAddress == address(0) || _pasarEscrowAddress == address(0) || _pasarAdminAddress == address(0))
            revert InvalidAddress();

        // Initialize OpenZeppelin Base Contracts for upgradeability.
        // __Initializable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // Store immutable and mutable addresses.
        ACCESS_MANAGER_ADDRESS = _accessManagerAddress; // Set immutable AccessManager address.
        pasarEscrowAddress = _pasarEscrowAddress;       // Set PasarEscrow address.
        pasarAdminAddress = _pasarAdminAddress;         // Set PasarAdmin address for upgrade authorization.

        // Grant DEFAULT_ADMIN_ROLE to the deployer of this contract.
        // This allows the deployer to manage roles within this specific contract.
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ============================
    // External Functions
    // ============================

    /// @notice Allows a party involved in an order to formally open a dispute.
    /// @dev This function records the dispute details on-chain and sets its status to 'Open'.
    ///      It is callable by the buyer or seller of the associated order.
    /// @param _orderId The unique identifier of the order for which the dispute is being opened.
    /// @param _buyer The address of the buyer in the order.
    /// @param _seller The address of the seller in the order.
    /// @param _amount The total amount of funds involved in the order.
    /// @param _token The address of the ERC-20 token used in the order.
    function openDispute(
        bytes32 _orderId,
        address _buyer,
        address _seller,
        uint256 _amount,
        address _token
    )
        external
        whenNotPaused      // Cannot be called if the contract is paused.
        nonReentrant       // Prevents reentrancy attacks.
    {
        // Input Validation: Ensure addresses are valid.
        if (_buyer == address(0) || _seller == address(0) || _token == address(0)) revert InvalidAddress();

        // Authorization: Only the buyer or seller of the order can open a dispute.
        // This assumes order details can be verified off-chain or through another contract.
        // For a full system, you might need to query PasarEscrow or an Order contract here
        // to verify _orderId, _buyer, and _seller. For this prompt, we'll assume they are correct.
        if (msg.sender != _buyer && msg.sender != _seller) revert UnauthorizedDisputeInitiator();

        // Generate a unique dispute ID. Using keccak256 of orderId and timestamp for uniqueness.
        bytes32 disputeId = keccak256(abi.encode(_orderId, block.timestamp));

        // State Validation: Ensure a dispute for this order isn't already open.
        // Note: This check relies on the disputeId being unique per order + timestamp.
        // If an order can have only one dispute ever, you might map orderId to disputeId.
        if (disputes[disputeId].exists) revert DisputeAlreadyOpen();

        // Store dispute details.
        disputes[disputeId] = Dispute({
            orderId: _orderId,
            buyer: _buyer,
            seller: _seller,
            amount: _amount,
            token: _token,
            initiatedAt: block.timestamp,
            status: DisputeStatus.Open, // Set status to Open.
            exists: true
        });

        // Add to active disputes queue for easy iteration/indexing.
        activeDisputes.push(disputeId);

        // Emit event for off-chain monitoring.
        emit DisputeOpened(disputeId, _orderId, _buyer, _seller, _amount, _token);
    }

    /// @notice Records the final verdict of a dispute on-chain.
    /// @dev This function is called by the trusted Backend Dispute Service (holding DISPUTE_MANAGER_ROLE)
    ///      after AI/human arbitration has determined the outcome.
    /// @param _disputeId The unique ID of the dispute for which the verdict is being submitted.
    /// @param _outcome The determined outcome of the dispute (e.g., RefundBuyer, ReleaseToSeller).
    function submitVerdict(bytes32 _disputeId, VerdictType _outcome)
        external
        onlyRole(DISPUTE_MANAGER_ROLE) // Only the trusted dispute manager can submit verdicts.
        whenNotPaused                  // Cannot be called if the contract is paused.
        nonReentrant                   // Prevents reentrancy attacks.
    {
        // State Validation: Ensure the dispute exists and is currently open.
        if (!disputes[_disputeId].exists) revert InvalidDisputeId();
        if (disputes[_disputeId].status != DisputeStatus.Open) revert DisputeNotOpen();
        // State Validation: Ensure a verdict hasn't been submitted already.
        if (verdicts[_disputeId].exists) revert VerdictAlreadySubmitted();
        // Input Validation: Ensure outcome is not 'None'.
        if (_outcome == VerdictType.None) revert UnauthorizedVerdictSubmission();

        // Store the verdict details.
        verdicts[_disputeId] = Verdict({
            disputeId: _disputeId,
            outcome: _outcome,
            resolvedAt: block.timestamp,
            exists: true
        });

        // Update dispute status to 'Resolved'.
        disputes[_disputeId].status = DisputeStatus.Resolved;

        // Emit event for off-chain monitoring.
        emit VerdictSubmitted(_disputeId, _outcome, msg.sender);
    }

    /// @notice Executes the recorded verdict by making a direct call to the PasarEscrow contract.
    /// @dev This function is called by the trusted Backend Dispute Service (holding DISPUTE_MANAGER_ROLE)
    ///      after a verdict has been submitted and the dispute is in a 'Resolved' state.
    ///      It triggers the actual fund transfers.
    /// @param _disputeId The unique ID of the dispute whose verdict is to be executed.
    function executeVerdict(bytes32 _disputeId)
        external
        onlyRole(DISPUTE_MANAGER_ROLE) // Only the trusted dispute manager can execute verdicts.
        whenNotPaused                  // Cannot be called if the contract is paused.
        nonReentrant                   // Prevents reentrancy attacks.
    {
        // State Validation: Ensure the dispute exists and has a submitted verdict.
        if (!disputes[_disputeId].exists) revert InvalidDisputeId();
        if (disputes[_disputeId].status != DisputeStatus.Resolved) revert DisputeNotResolved();
        if (!verdicts[_disputeId].exists) revert VerdictNotSubmitted();
        if (pasarEscrowAddress == address(0)) revert InvalidEscrowAddress(); // Ensure escrow address is set.

        // Retrieve dispute and verdict details.
        Dispute storage disputeData = disputes[_disputeId];
        Verdict memory verdictData = verdicts[_disputeId];

        // Instantiate PasarEscrow contract interface.
        IPasarEscrow escrow = IPasarEscrow(pasarEscrowAddress);

        // Execute actions based on the verdict outcome.
        if (verdictData.outcome == VerdictType.RefundBuyer) {
            escrow.refundBuyer(disputeData.orderId);
        } else if (verdictData.outcome == VerdictType.ReleaseToCryptoSeller) {
            // This requires the seller's crypto address from the original order or dispute details.
            // Assuming disputeData.seller holds the sellerCryptoAddress for crypto sellers.
            escrow.releaseFundsToCryptoSeller(disputeData.orderId, disputeData.seller);
        } else if (verdictData.outcome == VerdictType.ReleaseToFiatSeller) {
            // This requires the seller's ID hash for fiat sellers.
            // Assuming disputeData.seller is a placeholder for sellerIdHash in this context
            // or that PasarEscrow can derive it from orderId.
            // In a real system, you might need to pass sellerIdHash directly if not derivable.
            bytes32 sellerIdHash = keccak256(abi.encodePacked(disputeData.seller)); // Placeholder: derive from seller address
            escrow.releaseFundsToPlatformForFiatSeller(disputeData.orderId, sellerIdHash);
        } else if (verdictData.outcome == VerdictType.SplitFunds) {
            // This case would require additional parameters in Verdict struct (e.g., buyerShare, sellerShare)
            // and a corresponding function in IPasarEscrow.
            // escrow.splitFunds(disputeData.orderId, verdictData.buyerShare, verdictData.sellerShare);
            revert UnauthorizedOperation(); // Or a more specific error if SplitFunds is not fully implemented.
        } else {
            revert UnauthorizedOperation(); // Should not happen if verdict is valid.
        }

        // Update dispute status to 'Closed'.
        disputeData.status = DisputeStatus.Closed;

        // Remove dispute from active queue.
        for (uint256 i = 0; i < activeDisputes.length; i++) {
            if (activeDisputes[i] == _disputeId) {
                activeDisputes[i] = activeDisputes[activeDisputes.length - 1];
                activeDisputes.pop();
                break;
            }
        }

        // Emit events for off-chain monitoring.
        emit VerdictExecuted(_disputeId, verdictData.outcome, msg.sender);
        emit DisputeClosed(_disputeId, DisputeStatus.Closed);
    }

    // ============================
    // View Functions
    // ============================

    /// @notice Returns the current status of a specific dispute.
    /// @param _disputeId The unique ID of the dispute.
    /// @return The current `DisputeStatus` of the dispute.
    function getDisputeStatus(bytes32 _disputeId) public view returns (DisputeStatus) {
        if (!disputes[_disputeId].exists) revert InvalidDisputeId();
        return disputes[_disputeId].status;
    }

    /// @notice Returns the details of the submitted verdict for a specific dispute.
    /// @param _disputeId The unique ID of the dispute.
    /// @return A `Verdict` struct containing the outcome, resolution timestamp, and existence flag.
    function getVerdict(bytes32 _disputeId) public view returns (Verdict memory) {
        if (!disputes[_disputeId].exists) revert InvalidDisputeId();
        if (!verdicts[_disputeId].exists) revert VerdictNotSubmitted();
        return verdicts[_disputeId];
    }

    /// @notice Returns the details of a specific dispute.
    /// @param _disputeId The unique ID of the dispute.
    /// @return A `Dispute` struct containing all details of the dispute.
    function getDispute(bytes32 _disputeId) public view returns (Dispute memory) {
        if (!disputes[_disputeId].exists) revert InvalidDisputeId();
        return disputes[_disputeId];
    }

    /// @notice Returns a list of all currently active dispute IDs.
    /// @dev This function can be used by off-chain indexers to find disputes that are not yet closed.
    /// @return An array of `bytes32` representing the IDs of active disputes.
    function getActiveDisputes() external view returns (bytes32[] memory) {
        return activeDisputes;
    }

    // ============================
    // Internal Functions (UUPS Upgradeability)
    // ============================

    /// @notice Authorizes contract upgrades for this `PasarDispute` contract.
    /// @dev This function is an override from `UUPSUpgradeable` and defines who can trigger an upgrade
    ///      of this specific `PasarDispute` contract. It is a critical security gate.
    ///      It requires the caller to be the `PasarAdmin` contract (your Timelock/Governance).
    /// @param newImplementation The address of the new implementation contract to upgrade to.
    function _authorizeUpgrade(address newImplementation)
        internal
        override          // Overrides the virtual function from UUPSUpgradeable.
        whenNotPaused     // Cannot be called if the contract is paused.
        nonReentrant      // Prevents reentrancy attacks during upgrade authorization.
    {
        // Security Check: Ensures that only the designated `PasarAdmin` contract (your Timelock)
        // can trigger an upgrade of this PasarDispute contract.
        if (msg.sender != pasarAdminAddress) revert UnauthorizedOperation();
        // Input Validation: Ensures the new implementation address is not the zero address.
        if (newImplementation == address(0)) revert InvalidAddress();
    }

    // ============================
    // Storage Gap for Upgradeability
    // ============================

    /// @dev This is a special variable used in upgradeable contracts to ensure storage layout consistency
    ///      between different versions. It acts as a buffer to prevent storage collisions when new state
    ///      variables are added in future versions of the contract, preserving existing data.
    uint256[50] private __gap;
}
