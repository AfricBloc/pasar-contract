// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

    /**
     * @title PasarThriftVault
     * @author Emperor
     * This contract allows users to set savings goals and deposit funds towards those goals.
     * Once the goal is met, users can withdraw the funds to an escrow contract.
     * 
     * @dev The contract is Ownable and uses ReentrancyGuard to prevent re-entrancy attacks.
     * @notice Users can only set one savings goal at a time.
     **/ 

contract PasarThriftVault is Ownable, ReentrancyGuard{

    //////////////////////
    // Errors           //
    //////////////////////

    error PasarThriftVault__InvalidEscrowAddress();
    error PasarThriftVault__MustBeGreaterThanZero();
    error PasarThrift__NoGoalSet();
    error PasarThrift__DepositAmountMustBePositive();
    error PasarThrift__TransferFailed();

    //////////////////////
    // State Variables  // 
    //////////////////////

    struct SavingsGoal {
        address token;
        uint256 goalAmount;
        uint256 currentAmount;
        bool withdrawn;
    }
    mapping(address => SavingsGoal) private s_savingsGoals;
    address private immutable i_escrowContract;

    //////////////////////
    // Events           // 
    //////////////////////

    event GoalSet(address indexed user, address indexed token, uint256 amount);
    event Deposited(address indexed user, uint256 amount, uint256 totalSaved);
    event GoalWithdrawn(address indexed user, uint256 amount);

    //////////////////////
    // Functions        //
    //////////////////////
    constructor(address escrowContract) Ownable(msg.sender){
        if(i_escrowContract == address(0)){
            revert PasarThriftVault__InvalidEscrowAddress();
        }
        i_escrowContract = escrowContract;
    }
    //////////////////////////
    // External Functions   // 
    //////////////////////////

    /**
     * @notice Set a new savings goal
     * @param token The ERC20 token address ideally should be the Pasar stable coin
     * @param amount The goal amount to be saved
     */

    function setSavingsGoal(address token, uint256 amount) external {
        if(token == address(0) || amount == 0){
            revert PasarThriftVault__InvalidEscrowAddress();
        }
        if(amount <= 0){
            revert PasarThriftVault__MustBeGreaterThanZero();
        }
        if(s_savingsGoals[msg.sender].goalAmount > 0 ){
            revert PasarThriftVault__InvalidEscrowAddress();
        }
        s_savingsGoals[msg.sender] = SavingsGoal({
            token: token,
            goalAmount: amount,
            currentAmount: 0,
            withdrawn: false
        });

        emit GoalSet(msg.sender, token, amount);
    }

    /**
     * @notice Deposit stablecoins towards your savings goal
     * @param amount The amount to deposit
     */
    function deposit(uint256 amount) external nonReentrant {
        SavingsGoal storage goal = s_savingsGoals[msg.sender];
        if (goal.goalAmount == 0) revert PasarThrift__NoGoalSet();
        if (amount == 0) revert PasarThrift__DepositAmountMustBePositive();

        bool success = IERC20(goal.token).transferFrom(msg.sender, address(this), amount);
        if (!success) revert PasarThrift__TransferFailed();

        goal.currentAmount += amount;

        emit Deposited(msg.sender, amount, goal.currentAmount);
    }

    /**
     * @notice Withdraw funds to the escrow contract once the savings goal is met
     */

    function withdrawGoal() external nonReentrant {
        SavingsGoal storage goal = s_savingsGoals[msg.sender];
        if (goal.goalAmount == 0) revert PasarThrift__NoGoalSet();
        if (goal.currentAmount < goal.goalAmount) revert PasarThrift__DepositAmountMustBePositive();
        if (goal.withdrawn) revert PasarThriftVault__InvalidEscrowAddress();

        goal.withdrawn = true;

        bool success = IERC20(goal.token).transfer(i_escrowContract, goal.currentAmount);
        if (!success) revert PasarThrift__TransferFailed();

        emit GoalWithdrawn(msg.sender, goal.currentAmount);
    }
    /////////////////////////////////////////
    // Public & External view Functions    //
    /////////////////////////////////////////

    function getSavingsGoal() external view returns (SavingsGoal memory) {
        return s_savingsGoals[msg.sender];
    }
    function getEscrowContract() external view returns (address) {
        return i_escrowContract;
    }
}