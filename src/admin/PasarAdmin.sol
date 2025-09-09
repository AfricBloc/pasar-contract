// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PasarAdmin
/// @author Olujimi
/// @notice A Timelock Controller for managing upgrades in the Pasar protocol with Chainlink Automation.
/// @dev Extends OpenZeppelin's TimelockController with multi-target upgrade queuing, Chainlink Automation
///      for automated execution, reentrancy protection, pausability, and custom role management with timelocks.
///      Supports queuing upgrades for multiple contracts, with events to track manual vs. automated execution
///      and upkeep timing.
contract PasarAdmin is TimelockController, AutomationCompatibleInterface, ReentrancyGuard, Pausable {
    // ============================
    // Roles
    // ============================

    /// @notice Role identifier for authorized upgrade admins who can schedule, cancel, and execute upgrades.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ============================
    // Custom Errors
    // ============================

    /// @notice Thrown when a zero address is provided for a target or implementation.
    error InvalidAddress();
    /// @notice Thrown when attempting to schedule an upgrade for a target with an existing pending upgrade.
    /// @param target The address of the proxy contract with a pending upgrade.
    error UpgradeAlreadyPending(address target);
    /// @notice Thrown when attempting to cancel or execute an upgrade for a target with no pending upgrade.
    /// @param target The address of the proxy contract with no pending upgrade.
    error NoUpgradePending(address target);
    /// @notice Thrown when attempting to execute an upgrade before its timelock has expired.
    /// @param target The address of the proxy contract not yet ready for upgrade.
    error UpgradeTooEarly(address target);
    /// @notice Thrown when the low-level call to upgrade a proxy fails.
    /// @param target The address of the proxy contract that failed to upgrade.
    /// @param data The return data from the failed call for debugging.
    error UpgradeFailed(address target, bytes data);
    /// @notice Thrown when a non-Chainlink Keeper attempts to call performUpkeep.
    error OnlyChainlinkKeeper();
    /// @notice Thrown when performUpkeep is called before the cooldown period has elapsed.
    error UpkeepCooldownActive();
    /// @notice Thrown when attempting to execute or cancel a role change that does not exist or is not ready.
    /// @param operationId The operation ID of the role change.
    error RoleChangeNotReady(bytes32 operationId);

    error UnauthorizedOperation();
    // ============================
    // Events
    // ============================

    /// @notice Emitted when an upgrade is scheduled for a proxy contract.
    /// @param target The proxy contract to be upgraded.
    /// @param newImplementation The new implementation contract address.
    /// @param scheduleTime The timestamp when the upgrade can be executed.
    /// @param caller The address that scheduled the upgrade.
    event UpgradeScheduled(address indexed target, address indexed newImplementation, uint256 scheduleTime, address indexed caller);
    /// @notice Emitted when an upgrade is executed, either manually or via automation.
    /// @param target The proxy contract that was upgraded.
    /// @param newImplementation The new implementation contract address.
    /// @param executedAt The timestamp of execution.
    /// @param caller The address that triggered the execution.
    /// @param isAutomated True if triggered by Chainlink Automation, false if manual.
    event UpgradeExecuted(address indexed target, address indexed newImplementation, uint256 executedAt, address indexed caller, bool isAutomated);
    /// @notice Emitted when a scheduled upgrade is canceled.
    /// @param target The proxy contract whose upgrade was canceled.
    /// @param newImplementation The implementation address that was canceled.
    /// @param caller The address that canceled the upgrade.
    event UpgradeCancelled(address indexed target, address indexed newImplementation, address indexed caller);
    /// @notice Emitted when a role change (grant or revoke) is scheduled or canceled.
    /// @param account The account to modify.
    /// @param role The role to grant or revoke.
    /// @param grant True if granting, false if revoking.
    /// @param scheduleTime The timestamp when the role change can be executed (0 for cancellation).
    /// @param operationId The unique identifier for the role change operation.
    event RoleChangeScheduled(address indexed account, bytes32 indexed role, bool grant, uint256 scheduleTime, bytes32 operationId);
    /// @notice Emitted when a role change is executed.
    /// @param account The account modified.
    /// @param role The role granted or revoked.
    /// @param grant True if granted, false if revoked.
    event RoleChangeExecuted(address indexed account, bytes32 indexed role, bool grant);
    /// @notice Emitted when the Chainlink Keeper address is updated (not used in this version).
    event ChainlinkKeeperUpdated(address indexed keeper);
    /// @notice Emitted when Chainlink Automation performs an upkeep, logging the upkeep timestamp.
    /// @param lastUpkeepTime The timestamp of the upkeep execution.
    event UpkeepPerformed(uint256 lastUpkeepTime);

    // ============================
    // Upgrade State
    // ============================

    /// @notice Struct to store details of a pending upgrade for a proxy contract.
    struct PendingUpgrade {
        address target; // The proxy contract address.
        address newImplementation; // The new implementation contract address.
        uint256 scheduleTime; // The timestamp when the upgrade can be executed.
        bool exists; // Flag indicating if the upgrade is pending.
    }

    /// @notice Mapping of proxy addresses to their pending upgrade details.
    mapping(address => PendingUpgrade) public pendingUpgrades;
    /// @notice Array of proxy addresses with pending upgrades, used for Chainlink Automation.
    address[] public upgradeQueue;
    /// @notice Minimum delay (2 days) before an upgrade or role change can be executed.
    uint256 public constant MIN_DELAY = 2 days;

    // ============================
    // Role Management State
    // ============================

    /// @notice Struct to store details of a pending role change operation.
    /// @dev Used to track role changes with timelock functionality.
    struct PendingRoleChange {
        address account; // The account to modify.
        bytes32 role; // The role to grant or revoke.
        bool grant; // True for grant, false for revoke.
        uint256 scheduleTime; // When the change can be executed.
        bool exists; // If the change is pending.
    }

    /// @notice Mapping of operation IDs to their pending role changes.
    mapping(bytes32 => PendingRoleChange) public pendingRoleChanges;

    // ============================
    // Chainlink Keeper and Rate Limiting
    // ============================

    /// @notice Address of the Chainlink Keeper authorized to call performUpkeep.
    address public immutable chainlinkKeeper;
    /// @notice Timestamp of the last performUpkeep execution for rate limiting.
    uint256 public lastUpkeepTime;
    /// @notice Cooldown period (1 hour) between performUpkeep calls.
    uint256 public constant UPKEEP_COOLDOWN = 1 hours;

    // ============================
    // Constructor
    // ============================

    /// @notice Initializes the contract with roles, timelock, and Chainlink Keeper settings.
    /// @param proposers Addresses allowed to propose timelocked operations.
    /// @param executors Addresses allowed to execute timelocked operations.
    /// @param superAdmin Address to receive ADMIN_ROLE and DEFAULT_ADMIN_ROLE.
    /// @param _chainlinkKeeper Address of the Chainlink Keeper for automation.
    constructor(
        address[] memory proposers,
        address[] memory executors,
        address superAdmin,      // Will get DEFAULT_ADMIN_ROLE (can manage roles)
        address upgradeAdmin,   // Will get ADMIN_ROLE (can perform upgrades)
        address _chainlinkKeeper
    ) TimelockController(MIN_DELAY, proposers, executors, superAdmin) {
        // Validate the Chainlink Keeper address to prevent zero address.
        if (_chainlinkKeeper == address(0)) revert InvalidAddress();
        // Set the immutable Chainlink Keeper address for performUpkeep restriction.
        chainlinkKeeper = _chainlinkKeeper;
        // Grant ADMIN_ROLE to the admin for scheduling and executing upgrades.
        _grantRole(ADMIN_ROLE, upgradeAdmin);
        // Grant DEFAULT_ADMIN_ROLE to the admin for full control, including role management.
        _grantRole(DEFAULT_ADMIN_ROLE, superAdmin);
    }

    // ============================
    // Modifiers
    // ============================

    /// @notice Restricts function calls to the designated Chainlink Keeper.
    modifier onlyChainlinkKeeper() {
        // Revert if the caller is not the authorized Chainlink Keeper.
        if (msg.sender != chainlinkKeeper) revert OnlyChainlinkKeeper();
        _;
    }

    // ============================
    // Upgrade Logic
    // ============================

    /// @notice Schedules an upgrade for a proxy contract with a timelock delay.
    /// @dev Stores the upgrade details in pendingUpgrades and adds the target to upgradeQueue.
    ///      Restricted to ADMIN_ROLE and requires the contract to be unpaused.
    /// @param target The proxy contract to upgrade.
    /// @param newImplementation The new implementation contract address.
    function scheduleUpgrade(address target, address newImplementation) external onlyRole(ADMIN_ROLE) whenNotPaused {
        // Validate that neither target nor newImplementation is the zero address.
        if (target == address(0) || newImplementation == address(0)) revert InvalidAddress();
        // Check if an upgrade is already pending for this target.
        if (pendingUpgrades[target].exists) revert UpgradeAlreadyPending(target);

        // Calculate the execution timestamp (current time + 2 days).
        uint256 scheduledTime = block.timestamp + MIN_DELAY;
        // Store the upgrade details in the pendingUpgrades mapping.
        pendingUpgrades[target] = PendingUpgrade({
            target: target,
            newImplementation: newImplementation,
            scheduleTime: scheduledTime,
            exists: true
        });
        // Add the target to the upgradeQueue for Chainlink Automation.
        upgradeQueue.push(target);

        // Emit an event to log the scheduled upgrade.
        emit UpgradeScheduled(target, newImplementation, scheduledTime, msg.sender);
    }

    /// @notice Cancels a scheduled upgrade for a proxy contract.
    /// @dev Removes the upgrade from pendingUpgrades and upgradeQueue.
    ///      Restricted to ADMIN_ROLE and requires the contract to be unpaused.
    /// @param target The proxy contract whose upgrade is to be canceled.
    function cancelUpgrade(address target) external onlyRole(ADMIN_ROLE) whenNotPaused {
        // Check if an upgrade exists for the target.
        if (!pendingUpgrades[target].exists) revert NoUpgradePending(target);

        // Emit an event to log the cancellation.
        emit UpgradeCancelled(target, pendingUpgrades[target].newImplementation, msg.sender);
        // Remove the upgrade from the pendingUpgrades mapping.
        delete pendingUpgrades[target];

        // Iterate through upgradeQueue to find and remove the target.
        for (uint256 i = 0; i < upgradeQueue.length; i++) {
            if (upgradeQueue[i] == target) {
                // Swap the target with the last element for efficient removal.
                upgradeQueue[i] = upgradeQueue[upgradeQueue.length - 1];
                // Remove the last element from the array.
                upgradeQueue.pop();
                break;
            }
        }
    }

    /// @notice Manually executes a scheduled upgrade for a proxy contract.
    /// @dev Calls the internal _performUpgrade function with isAutomated=false.
    ///      Restricted to ADMIN_ROLE and requires the contract to be unpaused.
    /// @param target The proxy contract to upgrade.
    function performUpgrade(address target) external onlyRole(ADMIN_ROLE) whenNotPaused {
        // Execute the upgrade, marking it as a manual operation.
        _performUpgrade(target, false);
    }

    /// @dev Internal function to execute an upgrade, either manually or via automation.
    /// @param target The proxy contract to upgrade.
    /// @param isAutomated True if triggered by Chainlink Automation, false if manual.
    function _performUpgrade(address target, bool isAutomated) internal nonReentrant {
        // Cache the upgrade details for gas efficiency.
        PendingUpgrade memory upgrade = pendingUpgrades[target];
        // Verify that an upgrade exists for the target.
        if (!upgrade.exists) revert NoUpgradePending(target);
        // Check if the timelock period has passed.
        if (block.timestamp < upgrade.scheduleTime) revert UpgradeTooEarly(target);

        // Clear the upgrade from the pendingUpgrades mapping to prevent re-execution.
        delete pendingUpgrades[target];
        // Remove the target from the upgradeQueue.
        for (uint256 i = 0; i < upgradeQueue.length; i++) {
            if (upgradeQueue[i] == target) {
                // Swap the target with the last element for efficient removal.
                upgradeQueue[i] = upgradeQueue[upgradeQueue.length - 1];
                // Remove the last element from the array.
                upgradeQueue.pop();
                break;
            }
        }

        // Perform a low-level call to the proxy's upgradeTo function.
        (bool success, bytes memory data) = target.call(
            abi.encodeWithSignature("upgradeTo(address)", upgrade.newImplementation)
        );
        // Revert if the call fails, including return data for debugging.
        if (!success) revert UpgradeFailed(target, data);

        // Emit an event to log the successful upgrade, including execution path.
        emit UpgradeExecuted(target, upgrade.newImplementation, block.timestamp, msg.sender, isAutomated);
    }

    // ============================
    // Chainlink Automation
    // ============================

    /// @notice Checks if any pending upgrade is ready for execution by Chainlink Automation.
    /// @dev Iterates through upgradeQueue to find a target with an expired timelock.
    ///      Ignores checkData as it’s not needed in this implementation.
    // / @param checkData Not used; included for compatibility with Chainlink Automation.
    /// @return upkeepNeeded True if an upgrade is ready to be executed.
    /// @return performData The encoded target address for the ready upgrade.
    function checkUpkeep(bytes calldata /* checkData */) external view override returns (bool upkeepNeeded, bytes memory performData) {
        // Iterate through all targets in the upgradeQueue.
        for (uint256 i = 0; i < upgradeQueue.length; i++) {
            address target = upgradeQueue[i];
            // Retrieve the upgrade details for the target.
            PendingUpgrade memory upgrade = pendingUpgrades[target];
            // Check if the upgrade exists and its timelock has expired.
            if (upgrade.exists && block.timestamp >= upgrade.scheduleTime) {
                // Return true and encode the target address for performUpkeep.
                return (true, abi.encode(target));
            }
        }
        // Return false if no upgrades are ready.
        return (false, "");
    }

    /// @notice Executes an upgrade via Chainlink Automation.
    /// @dev Decodes the target address and calls _performUpgrade with isAutomated=true.
    ///      Restricted to the Chainlink Keeper and requires the contract to be unpaused.
    /// @param performData The encoded target address from checkUpkeep.
    function performUpkeep(bytes calldata performData) external override onlyChainlinkKeeper whenNotPaused {
        // Check if the cooldown period has elapsed since the last upkeep.
        if (block.timestamp < lastUpkeepTime + UPKEEP_COOLDOWN) revert UpkeepCooldownActive();
        // Update the last upkeep timestamp.
        lastUpkeepTime = block.timestamp;
        // Emit an event to log the upkeep execution time.
        emit UpkeepPerformed(lastUpkeepTime);
        // Decode the target address from performData.
        address target = abi.decode(performData, (address));
        // Execute the upgrade, marking it as an automated operation.
        _performUpgrade(target, true);
    }

    // ============================
    // Role Management
    // ============================

    /// @notice Schedules a role change with a timelock delay.
    /// @dev Creates a unique operation ID and stores the role change details in pendingRoleChanges.
    ///      Restricted to DEFAULT_ADMIN_ROLE and requires the contract to be unpaused.
    /// @param account The account to grant or revoke the role for.
    /// @param role The role to modify (e.g., ADMIN_ROLE or DEFAULT_ADMIN_ROLE).
    /// @param grant True to grant the role, false to revoke it.
    function scheduleRoleChange(address account, bytes32 role, bool grant) 
        external onlyRole(ADMIN_ROLE) whenNotPaused {
        if (account == address(0)) revert InvalidAddress();
        
        bytes32 operationId = keccak256(
            abi.encode(account, role, grant, block.timestamp)
        );
        
        pendingRoleChanges[operationId] = PendingRoleChange({
            account: account,
            role: role,
            grant: grant,
            scheduleTime: block.timestamp + MIN_DELAY,
            exists: true
        });

        emit RoleChangeScheduled(
            account, 
            role, 
            grant, 
            block.timestamp + MIN_DELAY, 
            operationId
        );
    }

    /// @notice Executes a pending role change after the timelock period.
    /// @dev Verifies timelock and executes the role change using _grantRole or _revokeRole.
    ///      Restricted to DEFAULT_ADMIN_ROLE and requires the contract to be unpaused.
    /// @param operationId The unique identifier of the pending role change.
    function executeRoleChange(bytes32 operationId) 
        external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        PendingRoleChange memory change = pendingRoleChanges[operationId];
        
        if (!change.exists) revert RoleChangeNotReady(operationId);
        if (block.timestamp < change.scheduleTime) revert RoleChangeNotReady(operationId);

        // Clear the pending change first to prevent reentrancy.
        delete pendingRoleChanges[operationId];

        // Execute the role change.
        if (change.grant) {
            _grantRole(change.role, change.account);
        } else {
            _revokeRole(change.role, change.account);
        }

        emit RoleChangeExecuted(change.account, change.role, change.grant);
    }

    /// @notice Checks if a role change operation is ready to execute.
    /// @dev Public view function for external verification of timelock status.
    /// @param operationId The operation ID to check.
    /// @return ready True if the operation can be executed.
    function isRoleChangeReady(bytes32 operationId) public view returns (bool ready) {
        PendingRoleChange memory change = pendingRoleChanges[operationId];
        return change.exists && block.timestamp >= change.scheduleTime;
    }

    /// @notice Cancels a pending role change operation.
    /// @dev Removes the role change from pendingRoleChanges. Restricted to DEFAULT_ADMIN_ROLE
    ///      and requires the contract to be unpaused.
    /// @param operationId The operation ID to cancel.
    function cancelRoleChange(bytes32 operationId) 
        external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        PendingRoleChange memory change = pendingRoleChanges[operationId];
        if (!change.exists) revert RoleChangeNotReady(operationId);
        
        delete pendingRoleChanges[operationId];
        
        emit RoleChangeScheduled(
            change.account,
            change.role,
            change.grant,
            0, // Indicates cancellation
            operationId
        );
    }

    // ============================
    // Pause Functionality
    // ============================

    /// @notice Pauses the contract, halting all critical operations.
    /// @dev Uses OpenZeppelin's Pausable to set the paused state.
    ///      Restricted to DEFAULT_ADMIN_ROLE.
    /// @dev When paused, the following operations are disabled:
    ///      - Scheduling new upgrades (scheduleUpgrade)
    ///      - Canceling pending upgrades (cancelUpgrade)
    ///      - Executing upgrades (performUpgrade)
    ///      - Scheduling role changes (scheduleRoleChange)
    ///      - Executing role changes (executeRoleChange)
    ///      - Canceling role changes (cancelRoleChange)
    ///      - Chainlink Keeper automated upgrades (performUpkeep)
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Set the contract to the paused state.
        _pause();
    }

    /// @notice Unpauses the contract, resuming all operations.
    /// @dev Uses OpenZeppelin's Pausable to clear the paused state.
    ///      Restricted to DEFAULT_ADMIN_ROLE.
    /// @dev Enables all previously paused operations including upgrades,
    ///      role management, and Chainlink automation.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Clear the paused state to resume operations.
        _unpause();
    }

    // ============================
    // Getter Functions
    // ============================

    /// @notice Returns the list of proxy contracts with pending upgrades.
    /// @dev Provides visibility into the upgradeQueue for off-chain monitoring.
    /// @return An array of addresses representing contracts with pending upgrades.
    function getUpgradeQueue() external view returns (address[] memory) {
        // Return the current upgradeQueue array.
        return upgradeQueue;
    }
}