AccessManager.sol
AccessManager.sol is a core smart contract for the Pasar protocol, designed to centralize and manage access control, system-wide state, and emergency operations. It serves as a base contract for other modules, ensuring consistent security policies across the ecosystem.

Key Features
Role-Based Access Control: Defines and manages various administrative and operational roles (e.g., DEFAULT_ADMIN_ROLE, ADMIN_ROLE, OPERATOR_ROLE, DISPUTE_MANAGER_ROLE, PLATFORM_SERVICE_ROLE).

User Blacklisting: Allows authorized roles to blacklist and unblacklist specific Ethereum addresses, restricting their access to protocol functionalities.

System Flags: Provides control over global operational flags (e.g., TRADING_ENABLED, WITHDRAWALS_ENABLED).

Pausability & Emergency Shutdown: Enables pausing the contract's operations and triggering a full system shutdown in emergencies, with corresponding restore functions.

Timelocked Admin Changes: Implements a secure, two-step process for changing critical admin addresses, involving a mandatory time delay.

Upgradeability: Built as a UUPS upgradeable contract, allowing its logic to be updated in the future.

Defined Roles
DEFAULT_ADMIN_ROLE: Super admin, highest authority, manages all other roles and emergency functions.

ADMIN_ROLE: Protocol admin, primarily involved in upgrade authorization.

OPERATOR_ROLE: Manages blacklist and day-to-day operations.

DISPUTE_MANAGER_ROLE: Authorizes on-chain dispute verdict submissions.

PLATFORM_SERVICE_ROLE: For trusted backend services and AI agents to perform automated on-chain actions.

Usage
This contract is used by higher-level administrators (human or automated) to configure PasarHQ protocol permissions, respond to security incidents, and manage the operational state of the Pasar ecosystem. Other Pasar smart contracts can inherit from or interact with AccessManager to enforce its defined roles and system-wide controls.