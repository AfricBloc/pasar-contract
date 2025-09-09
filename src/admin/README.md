PasarAdmin Smart Contract

Overview

PasarAdmin.sol is a governance smart contract designed for the Pasar protocol, built on Ethereum. It extends OpenZeppelin's TimelockController to manage upgrades for multiple proxy contracts and implements a custom role management system with a 2-day timelock. The contract integrates Chainlink Automation for automated upgrade execution, includes reentrancy protection, and supports pausability for emergency control. It is written in Solidity ^0.8.24 and is intended for secure, transparent, and decentralized protocol administration.
Key Features

Multi-Contract Upgrade Queuing: Schedules and executes upgrades for multiple proxy contracts with a 2-day timelock, supporting both manual and automated execution via Chainlink Automation.
Custom Role Management: Manages roles (ADMIN_ROLE and DEFAULT_ADMIN_ROLE) with a timelocked process for granting or revoking permissions, including cancellation functionality.
Security Mechanisms: Incorporates reentrancy protection (ReentrancyGuard), pausability (Pausable), and role-based access control to ensure secure operations.
Chainlink Automation: Uses Chainlink Keepers to automatically execute upgrades when their timelock expires, with a 1-hour cooldown between executions.
Auditability: Emits detailed events for upgrades, role changes, and automation activities, enabling transparent monitoring.


Here's a comprehensive list of what the PasarAdmin contract does:

Upgrade Management:

Schedules upgrades for proxy contracts with a 2-day timelock
Maintains a queue of pending upgrades
Allows cancellation of scheduled upgrades
Executes upgrades both manually and automatically
Verifies timelock periods before execution
Role Management:

Implements timelocked role changes (grant/revoke)
Maintains separation between DEFAULT_ADMIN_ROLE and ADMIN_ROLE
Tracks pending role changes with unique operation IDs
Allows cancellation of pending role changes
Enforces timelock period for role modifications
Chainlink Automation Integration:

Automates upgrade execution through Chainlink Keepers
Implements upkeep checks for pending upgrades
Enforces rate limiting (1-hour cooldown between automated executions)
Restricts automated execution to authorized Chainlink Keeper address
Tracks and logs automated upgrade executions
Security Features:

Implements pause/unpause functionality for emergency stops
Uses OpenZeppelin's TimelockController for delayed operations
Includes reentrancy protection for critical functions
Enforces role-based access control
Validates addresses and operation states
System Monitoring:

Emits detailed events for all major operations
Tracks upgrade scheduling, execution, and cancellation
Logs role changes and their execution status
Records Chainlink Keeper activities
Provides view functions for checking system state
Error Handling:

Custom error messages for various failure scenarios
Validates upgrade states and conditions
Checks for invalid addresses
Verifies timelock periods
Handles failed upgrade attempts with debugging information
Queue Management:

Maintains an ordered list of pending upgrades
Efficiently removes completed or cancelled upgrades
Provides methods to view the current upgrade queue
Handles multiple concurrent upgrade requests
Prevents duplicate upgrade scheduling
Timelock Enforcement:

2-day minimum delay for upgrades
Timelock for role changes
Prevents premature execution
Allows cancellation during timelock period
Separate delays for different operation types
Access Control:

Restricts upgrade scheduling to ADMIN_ROLE
Limits role management to DEFAULT_ADMIN_ROLE
Controls Chainlink Keeper access
Manages proposer and executor roles
Enforces separation of concerns between roles
State Management:

Tracks pending upgrades
Maintains role change operations
Records automation timestamps
Manages pause state
Stores Chainlink Keeper address


Contract Details
Dependencies

OpenZeppelin Contracts:
TimelockController: For managing timelocked operations (used for upgrades).
ReentrancyGuard: Prevents reentrancy attacks during upgrade and role change execution.
Pausable: Enables emergency pause/unpause functionality.


Chainlink Contracts:
AutomationCompatibleInterface: Supports Chainlink Keeper automation for upgrades.



Solidity Version

^0.8.24: Ensures compatibility with modern Solidity features and security practices.

Roles

ADMIN_ROLE (keccak256("ADMIN_ROLE")): Authorizes scheduling, canceling, and executing proxy contract upgrades.
DEFAULT_ADMIN_ROLE: Authorizes role management (granting/revoking roles), pausing/unpausing the contract, and inherits ADMIN_ROLE privileges.

State Variables

Upgrade Management:
PendingUpgrade struct: Stores target (proxy address), newImplementation (new logic contract), scheduleTime (execution timestamp), and exists (status flag).
pendingUpgrades mapping: Maps proxy addresses to their pending upgrades.
upgradeQueue array: Lists proxy addresses with pending upgrades for Chainlink Automation.


Role Management:
PendingRoleChange struct: Stores account, role, grant (true for grant, false for revoke), scheduleTime, and exists.
pendingRoleChanges mapping: Maps operation IDs (bytes32) to pending role changes.


Chainlink Automation:
chainlinkKeeper: Immutable address of the authorized Chainlink Keeper.
lastUpkeepTime: Tracks the last upkeep execution for cooldown enforcement.
UPKEEP_COOLDOWN (1 hour): Minimum interval between automated upkeep calls.


Timelock:
MIN_DELAY (2 days): Minimum delay for upgrades and role changes to ensure governance transparency.



Events

Upgrade Events:
UpgradeScheduled(address target, address newImplementation, uint256 scheduleTime, address caller): Emitted when an upgrade is scheduled.
UpgradeExecuted(address target, address newImplementation, uint256 executedAt, address caller, bool isAutomated): Emitted when an upgrade is executed (manually or automated).
UpgradeCancelled(address target, address newImplementation, address caller): Emitted when an upgrade is canceled.


Role Management Events:
RoleChangeScheduled(address account, bytes32 role, bool grant, uint256 scheduleTime, bytes32 operationId): Emitted when a role change is scheduled or canceled (scheduleTime = 0 for cancellation).
RoleChangeExecuted(address account, bytes32 role, bool grant): Emitted when a role change is executed.


Automation Events:
UpkeepPerformed(uint256 lastUpkeepTime): Emitted when Chainlink Automation executes an upkeep.
ChainlinkKeeperUpdated(address keeper): Reserved for future keeper updates (not used in this version).



Custom Errors

InvalidAddress(): Thrown for zero-address inputs.
UpgradeAlreadyPending(address target): Thrown when scheduling an upgrade for a proxy with an existing pending upgrade.
NoUpgradePending(address target): Thrown when canceling or executing a non-existent upgrade.
UpgradeTooEarly(address target): Thrown when executing an upgrade before its timelock expires.
UpgradeFailed(address target, bytes data): Thrown when a proxy upgrade call fails.
OnlyChainlinkKeeper(): Thrown when a non-keeper calls performUpkeep.
UpkeepCooldownActive(): Thrown when performUpkeep is called before the cooldown period.
RoleChangeNotReady(bytes32 operationId): Thrown for non-existent or premature role change operations.

Functionality
Upgrade Management

Scheduling Upgrades:
scheduleUpgrade(address target, address newImplementation): Schedules a proxy upgrade with a 2-day timelock, restricted to ADMIN_ROLE. Stores details in pendingUpgrades and adds target to upgradeQueue.


Canceling Upgrades:
cancelUpgrade(address target): Cancels a pending upgrade, removes it from pendingUpgrades and upgradeQueue, restricted to ADMIN_ROLE.


Executing Upgrades:
performUpgrade(address target): Manually executes a pending upgrade after the timelock, restricted to ADMIN_ROLE.
performUpkeep(bytes calldata performData): Automatically executes a pending upgrade via Chainlink Keeper, with a 1-hour cooldown.
_performUpgrade(address target, bool isAutomated): Internal function handling upgrade logic, including low-level calls to the proxy’s upgradeTo function.


Monitoring:
getUpgradeQueue(): Returns the list of proxy addresses with pending upgrades.
checkUpkeep(bytes calldata): Checks if any upgrade is ready for automated execution, returning the target address.



Role Management

Scheduling Role Changes:
scheduleRoleChange(address account, bytes32 role, bool grant): Schedules a role grant or revoke with a 2-day timelock, restricted to DEFAULT_ADMIN_ROLE. Generates a unique operationId using keccak256 and stores details in pendingRoleChanges.


Executing Role Changes:
executeRoleChange(bytes32 operationId): Executes a pending role change after the timelock, calling _grantRole or _revokeRole, restricted to DEFAULT_ADMIN_ROLE.


Canceling Role Changes:
cancelRoleChange(bytes32 operationId): Cancels a pending role change, clearing it from pendingRoleChanges, restricted to DEFAULT_ADMIN_ROLE.


Checking Readiness:
isRoleChangeReady(bytes32 operationId): Returns whether a role change is ready to execute based on its timelock.



Security Features

Access Control: Uses onlyRole(ADMIN_ROLE) for upgrades and onlyRole(DEFAULT_ADMIN_ROLE) for role management and pausing.
Timelock: Enforces a 2-day delay (MIN_DELAY) for upgrades and role changes to allow community review.
Pausability: pause() and unpause() (restricted to DEFAULT_ADMIN_ROLE) halt or resume operations in emergencies.
Reentrancy Protection: nonReentrant modifier prevents reentrancy attacks during upgrade and role change execution.
Chainlink Keeper Restriction: onlyChainlinkKeeper modifier ensures only the designated keeper can call performUpkeep.
Cooldown: UPKEEP_COOLDOWN (1 hour) prevents excessive automated executions.

Deployment
Prerequisites

Solidity Compiler: solc version 0.8.24 or compatible.
Dependencies: Install OpenZeppelin (@openzeppelin/contracts) and Chainlink (@chainlink/contracts) via npm or download from their respective repositories.npm install @openzeppelin/contracts @chainlink/contracts


Ethereum Network: Deploy on a mainnet or testnet (e.g., Sepolia, Goerli) with access to Chainlink Keepers.
Chainlink Keeper: Register the contract with Chainlink Automation and obtain the keeper address.

Deployment Steps

Prepare Constructor Parameters:
proposers: Array of addresses allowed to propose timelocked operations (for TimelockController upgrades).
executors: Array of addresses allowed to execute timelocked operations (for TimelockController upgrades).
admin: Address to receive ADMIN_ROLE and DEFAULT_ADMIN_ROLE.
_chainlinkKeeper: Address of the Chainlink Keeper for automated upkeep.


Compile the Contract:npx hardhat compile

Ensure hardhat.config.js specifies Solidity 0.8.24 and includes OpenZeppelin and Chainlink dependencies.
Deploy the Contract:Use a deployment script (e.g., with Hardhat):const PasarAdmin = await ethers.getContractFactory("PasarAdmin");
const pasarAdmin = await PasarAdmin.deploy(
    proposers, // e.g., ["0x..."]
    executors, // e.g., ["0x..."]
    admin,     // e.g., "0x..."
    chainlinkKeeper // e.g., "0x..."
);
await pasarAdmin.deployed();
console.log("PasarAdmin deployed to:", pasarAdmin.address);


Register with Chainlink Keepers:
Register the contract on Chainlink Automation with the checkUpkeep and performUpkeep functions.
Set the upkeep interval and gas limit as needed (e.g., check every 1 hour).


Verify the Contract:Verify on Etherscan or similar block explorer:npx hardhat verify --network <network> <contract-address> <constructor-args>



Configuration

Timelock: MIN_DELAY is set to 2 days (172800 seconds) and is immutable. Adjust in the source code if a different timelock is needed before deployment.
Cooldown: UPKEEP_COOLDOWN is set to 1 hour (3600 seconds) and is immutable. Modify in the source code if needed.
Roles: Ensure the admin address is secure (e.g., a multisig wallet) to prevent unauthorized role changes or pausing.

Usage
Scheduling an Upgrade
await pasarAdmin.scheduleUpgrade(proxyAddress, newImplementationAddress, { from: admin });


Requires ADMIN_ROLE.
Adds the upgrade to pendingUpgrades and upgradeQueue.
Emits UpgradeScheduled.

Executing an Upgrade

Manually:await pasarAdmin.performUpgrade(proxyAddress, { from: admin });


Requires ADMIN_ROLE and timelock expiration.
Emits UpgradeExecuted with isAutomated = false.


Automated:
Chainlink Keeper calls performUpkeep when checkUpkeep returns true.
Emits UpkeepPerformed and UpgradeExecuted with isAutomated = true.



Canceling an Upgrade
await pasarAdmin.cancelUpgrade(proxyAddress, { from: admin });


Requires ADMIN_ROLE.
Removes the upgrade from pendingUpgrades and upgradeQueue.
Emits UpgradeCancelled.

Managing Roles

Scheduling a Role Change:await pasarAdmin.scheduleRoleChange(account, role, true, { from: admin }); // Grant role
await pasarAdmin.scheduleRoleChange(account, role, false, { from: admin }); // Revoke role


Requires DEFAULT_ADMIN_ROLE.
Stores in pendingRoleChanges with a unique operationId.
Emits RoleChangeScheduled with scheduleTime = block.timestamp + MIN_DELAY.


Executing a Role Change:await pasarAdmin.executeRoleChange(operationId, { from: admin });


Requires DEFAULT_ADMIN_ROLE and timelock expiration.
Calls _grantRole or _revokeRole and clears pendingRoleChanges.
Emits RoleChangeExecuted.


Canceling a Role Change:await pasarAdmin.cancelRoleChange(operationId, { from: admin });


Requires DEFAULT_ADMIN_ROLE.
Clears pendingRoleChanges.
Emits RoleChangeScheduled with scheduleTime = 0.


Checking Role Change Readiness:const ready = await pasarAdmin.isRoleChangeReady(operationId);


Returns true if the role change is ready to execute.



Pausing/Unpausing

Pause:await pasarAdmin.pause({ from: admin });


Requires DEFAULT_ADMIN_ROLE.
Halts upgrades and role changes.


Unpause:await pasarAdmin.unpause({ from: admin });


Requires DEFAULT_ADMIN_ROLE.
Resumes normal operation.



Testing
Setup
Use Hardhat or Foundry for testing. Install dependencies:
npm install --save-dev hardhat @nomiclabs/hardhat-ethers ethers @openzeppelin/contracts @chainlink/contracts

### Setup

Use Foundry for testing. First install Foundry:

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Initialize a new Foundry project:

```bash
forge init

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts
forge install smartcontractkit/chainlink-brownie-contracts

# Update remappings.txt
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
@chainlink/contracts/=lib/chainlink-brownie-contracts/contracts/
```

Run tests:
```bash
forge test
```

Example test in Foundry (in `test/PasarAdmin.t.sol`):

````solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PasarAdmin} from "../src/admin/PasarAdmin.sol";

contract PasarAdminTest is Test {
    PasarAdmin public admin;
    address keeper = address(0x1);
    address proposer = address(0x2);
    address executor = address(0x3);
    address owner = address(0x4);

    function setUp() public {
        // Setup arrays for constructor
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;

        // Deploy contract
        vm.prank(owner);
        admin = new PasarAdmin(
            proposers,
            executors,
            owner,
            keeper
        );
    }

    function testScheduleAndExecuteRoleChange() public {
        bytes32 role = keccak256("ADMIN_ROLE");
        
        // Schedule role change
        vm.prank(owner);
        admin.scheduleRoleChange(proposer, role, true);

        // Advance time
        vm.warp(block.timestamp + 2 days);

        // Execute role change and verify
        bytes32 operationId = keccak256(
            abi.encode(proposer, role, true, block.timestamp - 2 days)
        );
        vm.prank(owner);
        admin.executeRoleChange(operationId);

        assertTrue(admin.hasRole(role, proposer));
    }
}

Test Cases

Upgrade Management:

Test scheduleUpgrade:
Verify pendingUpgrades and upgradeQueue updates.
Check UpgradeScheduled event.
Test zero-address reverts (InvalidAddress).
Test duplicate scheduling (UpgradeAlreadyPending).


Test cancelUpgrade:
Verify removal from pendingUpgrades and upgradeQueue.
Check UpgradeCancelled event.
Test non-existent upgrade (NoUpgradePending).


Test performUpgrade:
Advance time past MIN_DELAY and verify upgrade execution.
Check UpgradeExecuted event with isAutomated = false.
Test premature execution (UpgradeTooEarly) and non-existent upgrade (NoUpgradePending).


Test checkUpkeep and performUpkeep:
Schedule upgrades, advance time, and verify checkUpkeep returns true with encoded target.
Call performUpkeep with keeper address and verify UpkeepPerformed and UpgradeExecuted with isAutomated = true.
Test cooldown enforcement (UpkeepCooldownActive) and non-keeper calls (OnlyChainlinkKeeper).




Role Management:

Test scheduleRoleChange:
Verify pendingRoleChanges updates with unique operationId.
Check RoleChangeScheduled event with correct scheduleTime.
Test zero-address reverts (InvalidAddress).


Test executeRoleChange:
Advance time past MIN_DELAY and verify _grantRole or _revokeRole calls.
Check RoleChangeExecuted event and pendingRoleChanges clearing.
Test premature execution and non-existent operationId (RoleChangeNotReady).


Test cancelRoleChange:
Verify pendingRoleChanges clearing.
Check RoleChangeScheduled event with scheduleTime = 0.
Test non-existent operationId (RoleChangeNotReady).


Test isRoleChangeReady:
Verify returns true after timelock and false for non-existent or premature operations.




Security Tests:

Test onlyRole(ADMIN_ROLE) and onlyRole(DEFAULT_ADMIN_ROLE) restrictions.
Test whenNotPaused modifier by pausing and attempting operations.
Test reentrancy protection by attempting recursive calls to executeRoleChange or performUpgrade.
Test UPKEEP_COOLDOWN enforcement in performUpkeep.



Example Test (Hardhat)
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("PasarAdmin", function () {
  let PasarAdmin, pasarAdmin, admin, keeper, proposer, executor, proxy;
  beforeEach(async function () {
    [admin, keeper, proposer, executor] = await ethers.getSigners();
    PasarAdmin = await ethers.getContractFactory("PasarAdmin");
    pasarAdmin = await PasarAdmin.deploy(
      [proposer.address],
      [executor.address],
      admin.address,
      keeper.address
    );
    await pasarAdmin.deployed();
  });

  it("should schedule and execute a role change", async function () {
    const role = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ADMIN_ROLE"));
    const operationId = ethers.utils.keccak256(
      ethers.utils.defaultAbiCoder.encode(
        ["address", "bytes32", "bool", "uint256"],
        [proposer.address, role, true, await ethers.provider.getBlock("latest").timestamp]
      )
    );

    await pasarAdmin.connect(admin).scheduleRoleChange(proposer.address, role, true);
    await ethers.provider.send("evm_increaseTime", [2 * 24 * 60 * 60]); // Advance 2 days
    await ethers.provider.send("evm_mine");

    await expect(pasarAdmin.connect(admin).executeRoleChange(operationId))
      .to.emit(pasarAdmin, "RoleChangeExecuted")
      .withArgs(proposer.address, role, true);

    expect(await pasarAdmin.hasRole(role, proposer.address)).to.be.true;
  });
});

Security Considerations

Timelock: The 2-day MIN_DELAY ensures transparency for upgrades and role changes. Do not reduce without governance consensus.
Access Control: Secure the admin address (use a multisig like Gnosis Safe). Loss of DEFAULT_ADMIN_ROLE could lock critical functions.
Reentrancy: nonReentrant protects upgrade and role change execution, but test thoroughly with complex proxy contracts.
Chainlink Keeper: Ensure the chainlinkKeeper address is correct and registered with Chainlink Automation. Incorrect setup could halt automated upgrades.
Pausability: Use pause only in emergencies, as it halts all operations. Test unpause scenarios to ensure smooth recovery.
Operation ID Uniqueness: The keccak256(abi.encode(account, role, grant, block.timestamp)) ensures unique operationIds for role changes, but avoid scheduling identical role changes in the same block.

Scalability Considerations

Upgrade Queue: The upgradeQueue array is gas-efficient for small to medium queues but may become costly for large queues. Consider a doubly-linked list for high-throughput scenarios.
Role Changes: The pendingRoleChanges mapping is efficient for storage but lacks a queue for automation. Add a role change queue and integrate with checkUpkeep/performUpkeep for automated execution if needed.
Gas Costs: Upgrade execution involves low-level calls, and role changes involve storage updates. Monitor gas costs during testing and optimize if deploying on high-gas networks.

Future Enhancements

Automated Role Changes: Extend checkUpkeep and performUpkeep to process pendingRoleChanges for automated role change execution.
Monitoring Functions: Add getPendingRoleChanges to list all pending role changes, similar to getUpgradeQueue.
Duplicate Prevention: Add checks in scheduleRoleChange to prevent scheduling duplicate role changes for the same account and role.
Configurable Timelocks: Allow governance to adjust MIN_DELAY or UPKEEP_COOLDOWN via timelocked proposals.

License

MIT License: The contract is licensed under MIT, as specified in the SPDX header.

Contact
For questions, bug reports, or contributions, contact the Pasar protocol team or open an issue on the project repository.


