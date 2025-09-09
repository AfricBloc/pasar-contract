// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title AccessManager
/// @author Olujimi
/// @notice Manages access control and system state for the Pasar protocol, serving as a base contract
/// @dev UUPS Upgradeable implementation with tiered access control for inherited contracts.
///      This contract defines roles, manages blacklisting, controls system-wide flags,
///      provides emergency pause/shutdown capabilities, and handles timelocked admin changes.
contract AccessManager is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // ============================
    // Roles
    // ============================
    // These constants define the various roles within the Pasar protocol.
    // Each role grants specific permissions to perform certain actions.

    /// @notice Role identifier for authorized upgrade admins. This role is distinct from DEFAULT_ADMIN_ROLE
    ///         and is specifically used for managing contract upgrades via the PasarAdmin contract.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Role identifier for operational team members. This role typically handles day-to-day tasks
    ///         like managing the blacklist.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    /// @notice Role identifier for entities (e.g., backend service, human admin) authorized to manage disputes.
    ///         This role allows for submitting and executing dispute verdicts on-chain.
    bytes32 public constant DISPUTE_MANAGER_ROLE = keccak256("DISPUTE_MANAGER_ROLE");
    /// @notice Role identifier for trusted backend services and AI agents (e.g., Xiara, Shogun, Xena)
    ///         that need to perform automated, programmatic interactions with smart contracts.
    bytes32 public constant PLATFORM_SERVICE_ROLE = keccak256("PLATFORM_SERVICE_ROLE");

    // ============================
    // Custom Errors
    // ============================
    // Custom errors provide more descriptive and gas-efficient error messages compared to `require()` statements.

    /// @notice Thrown when a zero address (0x0...) is provided where a valid address is required.
    error InvalidAddress();
    /// @notice Thrown when a blacklisted user attempts to perform an action restricted to non-blacklisted users.
    /// @param user The address of the blacklisted user.
    error UserBlacklisted(address user);
    /// @notice Thrown when there is an inconsistency in role configuration, e.g., mismatched array lengths.
    error InvalidRoleConfiguration();
    /// @notice Thrown when an attempt is made to set a system flag that is not recognized or defined.
    /// @param flag The unrecognized system flag.
    error SystemFlagNotFound(bytes32 flag);
    /// @notice Thrown when an unauthorized address attempts to perform a restricted operation.
    error UnauthorizedOperation();
    /// @notice Thrown when a batch operation fails at a specific index.
    /// @param index The index at which the batch operation failed.
    error BatchOperationFailed(uint256 index);

    // ============================
    // Events
    // ============================
    // Events are emitted to provide a transparent, historical record of key actions on the blockchain.
    // They are crucial for off-chain monitoring, indexing, and auditing.

    /// @notice Emitted when a system-wide flag (like TRADING_ENABLED) is updated.
    /// @param flag The identifier of the system flag.
    /// @param status The new status (true/false) of the flag.
    /// @param operator The address that updated the flag.
    event SystemFlagUpdated(bytes32 indexed flag, bool status, address indexed operator);
    /// @notice Emitted when an address's blacklist status is changed.
    /// @param user The address whose blacklist status was changed.
    /// @param status The new blacklist status (true/false).
    /// @param operator The address that changed the blacklist status.
    event BlacklistStatusChanged(address indexed user, bool status, address indexed operator);
    /// @notice Emitted when a role is successfully assigned to an account.
    /// @param account The account that received the role.
    /// @param role The role that was assigned.
    /// @param assigner The address that assigned the role.
    event RoleAssigned(address indexed account, bytes32 indexed role, address indexed assigner);
    /// @notice Emitted when a role is successfully revoked from an account.
    /// @param account The account from which the role was revoked.
    /// @param role The role that was revoked.
    /// @param revoker The address that revoked the role.
    event RoleRevoked(address indexed account, bytes32 indexed role, address indexed revoker);
    /// @notice Emitted when the system enters an emergency shutdown state.
    /// @param operator The address that initiated the shutdown.
    event EmergencyShutdown(address indexed operator);
    /// @notice Emitted when the system is restored from an emergency shutdown state.
    /// @param operator The address that initiated the restoration.
    event SystemRestored(address indexed operator);
    /// @notice Emitted when a change to the super admin or PasarAdmin address is scheduled.
    /// @param newAdmin The address proposed to become the new admin.
    /// @param isSuperAdmin True if the change is for the DEFAULT_ADMIN_ROLE, false for ADMIN_ROLE.
    /// @param scheduleTime The timestamp when the admin change can be executed.
    /// @param operationId The unique identifier for this scheduled admin change operation.
    event AdminChangeScheduled(address indexed newAdmin, bool isSuperAdmin, uint256 scheduleTime, bytes32 indexed operationId);

    // ============================
    // State Variables
    // ============================
    // These variables define the contract's state, holding crucial information about the system's status and user permissions.

    /// @notice Tracks whether critical system functions are globally locked (true if locked).
    ///         This is part of the emergency shutdown mechanism.
    bool public systemLocked;
    /// @notice Stores the address of the PasarAdmin contract, which is the central governance and upgrade contract.
    ///         This allows AccessManager to verify calls coming from the official PasarAdmin for upgrades.
    address public pasarAdmin;
    /// @notice Stores the address of the super admin, which holds the DEFAULT_ADMIN_ROLE.
    ///         This is the highest authority in the system.
    address public superAdmin;
    /// @notice Maps predefined system flags (e.g., TRADING_ENABLED) to their current boolean status.
    ///         This allows for granular control over various platform functionalities.
    mapping(bytes32 => bool) public systemFlags;
    /// @notice Maps Ethereum addresses to their blacklist status (true if blacklisted, false otherwise).
    ///         This is used to restrict access for malicious or unauthorized users.
    mapping(address => bool) public isBlacklisted;

    /// @notice Struct to hold details for a pending change to a core admin address (superAdmin or pasarAdmin).
    ///         This enables timelocked changes for critical administrative roles.
    struct PendingAdminChange {
        address newAdmin;       // The proposed new admin address.
        uint256 scheduleTime;   // The timestamp after which the change can be executed.
        bool isSuperAdmin;      // True if the change is for superAdmin, false for pasarAdmin.
        bool exists;            // Flag indicating if a pending change exists for this operationId.
    }
    /// @notice Mapping of unique operation IDs to their corresponding PendingAdminChange details.
    mapping(bytes32 => PendingAdminChange) public pendingAdminChanges;

    /// @notice Minimum delay (2 days) that must pass between scheduling and executing certain critical operations,
    ///         such as admin changes. This provides a window for review and prevents rushed decisions.
    uint256 public constant MIN_DELAY = 2 days;

    /// @notice Predefined system flag to control the overall trading functionality of the platform.
    bytes32 public constant TRADING_ENABLED = keccak256("TRADING_ENABLED");
    /// @notice Predefined system flag to control the overall withdrawal functionality of the platform.
    bytes32 public constant WITHDRAWALS_ENABLED = keccak256("WITHDRAWALS_ENABLED");

    // ============================
    // Initialization
    // ============================
    // As an upgradeable contract, `AccessManager` uses an `initialize()` function instead of a constructor.
    // This function is called only once to set up the initial state and grant initial roles.
    // It is critical to call this function immediately after deployment of the proxy.

    /// @notice Initializes the contract and sets up initial roles for the Pasar protocol.
    /// @param _pasarAdmin The initial address of the PasarAdmin contract, which will hold the ADMIN_ROLE.
    /// @param _superAdmin The initial address to receive the DEFAULT_ADMIN_ROLE privileges (the highest authority).
    /// @param operators An array of addresses to receive the OPERATOR_ROLE during initial setup.
    function initialize(
        address _pasarAdmin,
        address _superAdmin,
        address[] calldata operators
    ) public initializer {
        // Input Validation: Ensures no zero addresses are provided for critical roles and that at least one operator is provided.
        if (_superAdmin == address(0) || _pasarAdmin == address(0) || operators.length == 0) revert InvalidAddress();

        // Initialize OpenZeppelin Base Contracts: Calls the initializer functions of all inherited OpenZeppelin modules.
        // This is crucial for setting up their internal state correctly for upgradeability.
        __AccessControl_init();   // Initializes AccessControl's internal state.
        __Pausable_init();        // Initializes Pausable's internal state (sets paused to false).
        __ReentrancyGuard_init(); // Initializes ReentrancyGuard's internal state.
        __UUPSUpgradeable_init(); // Initializes UUPSUpgradeable's internal state.

        // Store Admin Addresses: Assigns the provided admin addresses to the contract's state variables.
        superAdmin = _superAdmin; // Sets the initial super admin.
        pasarAdmin = _pasarAdmin; // Sets the initial PasarAdmin contract address.

        // Grant Initial Roles: Assigns the fundamental roles in the system.
        // The DEFAULT_ADMIN_ROLE is the highest privilege, controlling all other roles.
        _grantRole(DEFAULT_ADMIN_ROLE, superAdmin);
        emit RoleAssigned(superAdmin, DEFAULT_ADMIN_ROLE, msg.sender); // Logs the role assignment.

        // The ADMIN_ROLE is assigned to the PasarAdmin contract, which manages upgrades.
        _grantRole(ADMIN_ROLE, pasarAdmin);
        emit RoleAssigned(pasarAdmin, ADMIN_ROLE, msg.sender); // Logs the role assignment.

        // Grant Operator Roles: Iterates through the provided list of operators and grants them the OPERATOR_ROLE.
        for (uint256 i = 0; i < operators.length; i++) {
            // Input Validation: Ensures operator addresses are valid and not already higher-privileged admins.
            // This prevents accidental or malicious assignment of a lower role to a critical admin address.
            if (operators[i] == address(0) || operators[i] == superAdmin || operators[i] == pasarAdmin)
                revert InvalidRoleConfiguration();
            _grantRole(OPERATOR_ROLE, operators[i]); // Grants the OPERATOR_ROLE.
            emit RoleAssigned(operators[i], OPERATOR_ROLE, msg.sender); // Logs the role assignment.
        }
    }

    // ============================
    // Modifiers
    // ============================
    // Modifiers are reusable code blocks that are prepended to a function to enforce certain conditions
    // before the function's main logic is executed.

    /// @notice Restricts function calls by blacklisted users.
    /// @dev If the `msg.sender` is found in the `isBlacklisted` mapping with a `true` status,
    ///      the transaction will revert.
    modifier notBlacklisted() {
        if (isBlacklisted[msg.sender]) revert UserBlacklisted(msg.sender);
        _; // Continues execution if not blacklisted.
    }

    /// @notice Restricts function calls when the system is in an emergency locked state.
    /// @dev If `systemLocked` is `true`, indicating an emergency shutdown, the transaction will revert.
    modifier whenSystemActive() {
        if (systemLocked) revert UnauthorizedOperation();
        _; // Continues execution if the system is active.
    }

    // ============================
    // Admin Functions
    // ============================
    // These functions provide the core administrative capabilities of the contract.
    // They are typically restricted to specific roles and often include checks for system state (paused/active).

    /// @notice Updates the status of a predefined system flag.
    /// @dev Allows the `DEFAULT_ADMIN_ROLE` to enable or disable specific platform functionalities.
    ///      Only `TRADING_ENABLED` and `WITHDRAWALS_ENABLED` flags can be set.
    /// @param flag The identifier of the system flag (e.g., `TRADING_ENABLED`).
    /// @param status The new status for the flag (true to enable, false to disable).
    function setSystemFlag(bytes32 flag, bool status)
        external
        onlyRole(DEFAULT_ADMIN_ROLE) // Only the super admin can change system flags.
        whenNotPaused                 // Cannot be called if the contract is paused.
        whenSystemActive              // Cannot be called if the system is in emergency locked state.
    {
        // Input Validation: Ensures only predefined flags can be updated.
        if (flag != TRADING_ENABLED && flag != WITHDRAWALS_ENABLED) revert SystemFlagNotFound(flag);
        systemFlags[flag] = status; // Update the flag's status in storage.
        emit SystemFlagUpdated(flag, status, msg.sender); // Log the update.
    }

    /// @notice Updates the blacklist status for a single user address.
    /// @dev Allows an `OPERATOR_ROLE` holder to add or remove an address from the blacklist.
    ///      Prevents blacklisting higher-privileged admin roles (ADMIN_ROLE, DEFAULT_ADMIN_ROLE).
    /// @param user The address to update.
    /// @param status The new blacklist status (true to blacklist, false to unblacklist).
    function setBlacklistStatus(address user, bool status)
        external
        onlyRole(OPERATOR_ROLE) // Only operators can manage the blacklist.
        whenNotPaused             // Cannot be called if the contract is paused.
        whenSystemActive          // Cannot be called if the system is in emergency locked state.
    {
        if (user == address(0)) revert InvalidAddress(); // Prevents zero address blacklisting.
        // Security Check: Prevents operators from blacklisting higher-privileged admin roles.
        if (hasRole(ADMIN_ROLE, user) || hasRole(DEFAULT_ADMIN_ROLE, user))
            revert UnauthorizedOperation();
        isBlacklisted[user] = status; // Update the blacklist status.
        emit BlacklistStatusChanged(user, status, msg.sender); // Log the change.
    }

    /// @notice Updates the blacklist status for multiple user addresses in a single transaction.
    /// @dev Provides an efficient way for an `OPERATOR_ROLE` holder to manage the blacklist in batches.
    ///      Includes the same security checks as `setBlacklistStatus` for each user.
    /// @param users An array of addresses to update.
    /// @param statuses An array of boolean statuses (true/false) corresponding to each user.
    function batchUpdateBlacklist(
        address[] calldata users,
        bool[] calldata statuses
    )
        external
        onlyRole(OPERATOR_ROLE) // Only operators can manage the blacklist.
        whenNotPaused             // Cannot be called if the contract is paused.
        whenSystemActive          // Cannot be called if the system is in emergency locked state.
    {
        // Input Validation: Ensures array lengths match to prevent errors.
        if (users.length != statuses.length) revert InvalidRoleConfiguration();
        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] == address(0)) revert InvalidAddress(); // Prevents zero address blacklisting.
            // Security Check: Prevents operators from blacklisting higher-privileged admin roles.
            if (hasRole(ADMIN_ROLE, users[i]) || hasRole(DEFAULT_ADMIN_ROLE, users[i]))
                revert UnauthorizedOperation();
            isBlacklisted[users[i]] = statuses[i]; // Update the blacklist status for each user.
            emit BlacklistStatusChanged(users[i], statuses[i], msg.sender); // Log each change.
        }
    }

    /// @notice Schedules a change for either the `superAdmin` (DEFAULT_ADMIN_ROLE) or `pasarAdmin` (ADMIN_ROLE) address.
    /// @dev This function initiates a two-step, timelocked process to update critical admin addresses.
    ///      A `MIN_DELAY` must pass before the change can be executed.
    /// @param newAdmin The new address proposed to be assigned the admin role.
    /// @param isSuperAdmin True if the change is for the `DEFAULT_ADMIN_ROLE`, false if for the `ADMIN_ROLE`.
    function scheduleAdminChange(address newAdmin, bool isSuperAdmin)
        external onlyRole(DEFAULT_ADMIN_ROLE) // Only the current super admin can schedule admin changes.
        whenNotPaused                        // Cannot be called if the contract is paused.
        whenSystemActive                     // Cannot be called if the system is in emergency locked state.
    {
        if (newAdmin == address(0)) revert InvalidAddress(); // Prevents setting zero address as admin.
        // Create a unique operation ID for this specific admin change.
        bytes32 operationId = keccak256(abi.encode(newAdmin, isSuperAdmin, block.timestamp));
        // Store the details of the pending admin change.
        pendingAdminChanges[operationId] = PendingAdminChange({
            newAdmin: newAdmin,
            scheduleTime: block.timestamp + MIN_DELAY, // Set the future execution time.
            isSuperAdmin: isSuperAdmin,
            exists: true
        });
        // Log the scheduled admin change.
        emit AdminChangeScheduled(newAdmin, isSuperAdmin, block.timestamp + MIN_DELAY, operationId);
    }

    /// @notice Executes a previously scheduled admin change after its timelock has passed.
    /// @dev This function finalizes the update of either the `superAdmin` or `pasarAdmin` address.
    /// @param operationId The unique identifier of the pending admin change to execute.
    function executeAdminChange(bytes32 operationId)
        external onlyRole(DEFAULT_ADMIN_ROLE) // Only the super admin can execute admin changes.
        whenNotPaused                        // Cannot be called if the contract is paused.
        whenSystemActive                     // Cannot be called if the system is in emergency locked state.
    {
        PendingAdminChange memory change = pendingAdminChanges[operationId];
        // Validation: Checks if the operation exists and if the timelock has passed.
        if (!change.exists || block.timestamp < change.scheduleTime) revert UnauthorizedOperation();
        delete pendingAdminChanges[operationId]; // Clear the pending change from storage to prevent re-execution.

        // Apply the role change based on whether it's for the superAdmin or PasarAdmin.
        if (change.isSuperAdmin) {
            _revokeRole(DEFAULT_ADMIN_ROLE, superAdmin); // Revoke role from old super admin.
            _grantRole(DEFAULT_ADMIN_ROLE, change.newAdmin); // Grant role to new super admin.
            superAdmin = change.newAdmin; // Update the superAdmin state variable.
        } else {
            _revokeRole(ADMIN_ROLE, pasarAdmin); // Revoke role from old PasarAdmin.
            _grantRole(ADMIN_ROLE, change.newAdmin); // Grant role to new PasarAdmin.
            pasarAdmin = change.newAdmin; // Update the pasarAdmin state variable.
        }
        // Log the successful role assignment.
        emit RoleAssigned(change.newAdmin, change.isSuperAdmin ? DEFAULT_ADMIN_ROLE : ADMIN_ROLE, msg.sender);
    }

    /// @notice Initiates an emergency shutdown of core system functions and pauses the contract.
    /// @dev This function sets `systemLocked` to `true` and calls the internal `_pause()` function
    ///      (inherited from `PausableUpgradeable`). It acts as a critical "kill switch" for the protocol.
    ///      Functions protected by `whenSystemActive` and `whenNotPaused` will be affected.
    function emergencyShutdown() external onlyRole(DEFAULT_ADMIN_ROLE) {
        systemLocked = true; // Set the system to a locked state.
        _pause();            // Pause the contract's operations.
        emit EmergencyShutdown(msg.sender); // Log the emergency shutdown.
    }

    /// @notice Restores core system functions and unpauses the contract after an emergency shutdown.
    /// @dev This function sets `systemLocked` to `false` and calls the internal `_unpause()` function
    ///      (inherited from `PausableUpgradeable`).
    function restoreSystem() external onlyRole(DEFAULT_ADMIN_ROLE) {
        systemLocked = false; // Set the system back to an active state.
        _unpause();           // Unpause the contract's operations.
        emit SystemRestored(msg.sender); // Log the system restoration.
    }

    /// @notice Pauses the contract, preventing calls to functions protected by `whenNotPaused`.
    /// @dev This function provides a direct way for the `DEFAULT_ADMIN_ROLE` to pause the contract's operations
    ///      without necessarily triggering a full `systemLocked` state. It's useful for maintenance.
    ///      It can only be called when the system is not in an `emergencyShutdown` state (`whenSystemActive`).
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) whenSystemActive {
        _pause(); // Calls the internal _pause() function from PausableUpgradeable.
    }

    /// @notice Unpauses the contract, allowing calls to functions protected by `whenNotPaused` again.
    /// @dev This function provides a direct way for the `DEFAULT_ADMIN_ROLE` to unpause the contract's operations.
    ///      It can only be called when the system is not in an `emergencyShutdown` state (`whenSystemActive`).
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) whenSystemActive {
        _unpause(); // Calls the internal _unpause() function from PausableUpgradeable.
    }


    // ============================
    // View Functions
    // ============================
    // These functions provide read-only access to the contract's state without altering it.
    // They are typically `view` or `pure` functions and do not consume gas (except for transaction costs).

    /// @notice Checks if a given address has operator privileges.
    /// @param account The address to check.
    /// @return True if the address holds the `OPERATOR_ROLE`, false otherwise.
    function isOperator(address account) external view returns (bool) {
        return hasRole(OPERATOR_ROLE, account);
    }

    /// @notice Retrieves all specific roles (excluding DEFAULT_ADMIN_ROLE if not explicitly granted)
    ///         assigned to a given address.
    /// @dev This function iterates through a predefined list of roles and checks if the account has each.
    /// @param account The address to check.
    /// @return An array of `bytes32` role identifiers held by the account.
    function getAccountRoles(address account) external view returns (bytes32[] memory roles) {
        // Define all roles to check.
        bytes32[] memory allRoles = new bytes32[](4);
        allRoles[0] = DEFAULT_ADMIN_ROLE; // Include DEFAULT_ADMIN_ROLE for completeness.
        allRoles[1] = ADMIN_ROLE;
        allRoles[2] = OPERATOR_ROLE;
        allRoles[3] = PLATFORM_SERVICE_ROLE;

        uint256 count = 0;
        // Count how many roles the account has.
        for (uint256 i = 0; i < allRoles.length; i++) {
            if (hasRole(allRoles[i], account)) count++;
        }

        // Create a new array with the exact size needed.
        roles = new bytes32[](count);
        uint256 index = 0;
        // Populate the array with the roles the account holds.
        for (uint256 i = 0; i < allRoles.length; i++) {
            if (hasRole(allRoles[i], account)) {
                roles[index] = allRoles[i];
                index++;
            }
        }
        return roles;
    }

    /// @notice Checks if a scheduled admin change operation is ready for execution.
    /// @dev This public view function allows external parties to verify the timelock status
    ///      of a pending admin change before attempting to execute it.
    /// @param operationId The unique identifier of the pending admin change to check.
    /// @return True if the operation exists and its `scheduleTime` has passed, false otherwise.
    function isAdminChangeReady(bytes32 operationId) public view returns (bool ready) {
        PendingAdminChange memory change = pendingAdminChanges[operationId];
        return change.exists && block.timestamp >= change.scheduleTime;
    }

    /// @notice Cancels a pending admin change operation.
    /// @dev This function removes the scheduled admin change from `pendingAdminChanges`.
    ///      It is restricted to the `DEFAULT_ADMIN_ROLE` and can only be called when the contract
    ///      is not paused and the system is active.
    /// @param operationId The unique identifier of the pending admin change to cancel.
    function cancelAdminChange(bytes32 operationId)
        external onlyRole(DEFAULT_ADMIN_ROLE) // Only the super admin can cancel admin changes.
        whenNotPaused                        // Cannot be called if the contract is paused.
        whenSystemActive                     // Cannot be called if the system is in emergency locked state.
    {
        PendingAdminChange memory change = pendingAdminChanges[operationId];
        // Validation: Checks if the operation exists. Using UnauthorizedOperation for consistency
        // with other admin-related error handling, implying the operation ID is invalid or not found.
        if (!change.exists) revert UnauthorizedOperation();
        delete pendingAdminChanges[operationId]; // Remove the pending change from storage.
        // Emitting AdminChangeScheduled with scheduleTime 0 to explicitly indicate cancellation.
        emit AdminChangeScheduled(
            change.newAdmin,
            change.isSuperAdmin,
            0, // `0` timestamp is used as a convention to signify cancellation.
            operationId
        );
    }

    // ============================
    // Internal Functions
    // ============================
    // Internal functions are not directly callable from outside the contract but are essential for its internal logic.

    /// @notice Authorizes contract upgrades for this `AccessManager` contract.
    /// @dev This function is an override from `UUPSUpgradeable` and defines who can trigger an upgrade
    ///      of this specific `AccessManager` contract. It is a critical security gate.
    ///      It requires the caller to be the `PasarAdmin` contract (which holds the `ADMIN_ROLE`)
    ///      and for the system to be active.
    /// @param newImplementation The address of the new implementation contract to upgrade to.
    function _authorizeUpgrade(address newImplementation)
        internal
        override          // Overrides the virtual function from UUPSUpgradeable.
        onlyRole(ADMIN_ROLE) // Requires the caller to have the ADMIN_ROLE.
        whenSystemActive  // Cannot be called if the system is in emergency locked state.
    {
        // Critical Security Check: Ensures that only the designated `PasarAdmin` contract
        // (which is a timelocked governance contract) can trigger an upgrade of this AccessManager.
        // This prevents direct, untimelocked upgrades by a single admin key.
        if (msg.sender != pasarAdmin) revert UnauthorizedOperation();
        // Input Validation: Ensures the new implementation address is not the zero address.
        if (newImplementation == address(0)) revert InvalidAddress();
    }

    // Virtual functions for inherited contracts
    // These functions are defined as `virtual` in AccessManager, meaning they provide an interface
    // but their actual implementation is expected in contracts that inherit from AccessManager.

    /// @notice Virtual function to resolve a dispute. Intended to be overridden by a contract like `PasarDispute`.
    /// @dev This function provides a standardized interface for dispute resolution within the Pasar ecosystem.
    ///      It is protected by the `DISPUTE_MANAGER_ROLE` and system state checks.
    /// @param disputeId The unique ID of the dispute to resolve.
    /// @param winner The address of the party who won the dispute (e.g., buyer or seller).
    function resolveDispute(uint256 disputeId, address winner)
        external
        virtual // Marks the function as virtual, allowing derived contracts to override it.
        onlyRole(DISPUTE_MANAGER_ROLE) // Only dispute managers can call this.
        whenNotPaused                 // Cannot be called if the contract is paused.
        whenSystemActive              // Cannot be called if the system is in emergency locked state.
    {
        if (winner == address(0)) revert InvalidAddress(); // Basic validation.
        // Placeholder for inherited contract implementation:
        // A contract like `PasarDispute` would implement the actual logic here,
        // e.g., updating dispute status, triggering escrow actions.
    }

    /// @notice Virtual function to manage platform services. Intended to be overridden by a specific service contract.
    /// @dev This function provides a standardized interface for managing various platform services,
    ///      allowing the `PLATFORM_SERVICE_ROLE` to enable or disable them.
    /// @param serviceId The unique identifier of the service to manage.
    /// @param enable True to enable the service, false to disable.
    function managePlatformService(bytes32 serviceId, bool enable)
        external
        virtual // Marks the function as virtual.
        onlyRole(PLATFORM_SERVICE_ROLE) // Only platform services can call this.
        whenNotPaused                 // Cannot be called if the contract is paused.
        whenSystemActive              // Cannot be called if the system is in emergency locked state.
    {
        // Placeholder for inherited contract implementation:
        // A derived contract would implement logic here to manage a specific service
        // identified by `serviceId`, e.g., enabling/disabling a feature.
    }

    // ============================
    // Storage Gap for Upgradeability
    // ============================

    /// @dev This is a special variable used in upgradeable contracts to ensure storage layout consistency
    ///      between different versions. It acts as a buffer to prevent storage collisions when new state
    ///      variables are added in future versions of the contract, preserving existing data.
    uint256[50] private __gap;
}
