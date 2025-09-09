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

pragma solidity  ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PasarEscrow is Ownable, ReentrancyGuard{

    //////////////////////
    // Errors           //
    //////////////////////

    error PasarEscrow__ThisUserIsNotTheBuyer();
    error PasarEscrow__InvalidTreasuryAddress();
    error PasarEscrow__OrderDoesNotExist();
    error PasarEscrow__OrderAlreadyExists();
    error PasarEscrow__MustBeGreaterThanZero();
    error PasarEscrow__OrderNotLocked();
    error PasarEscrow__CannotDisputeOrder();
    error PaserEscrow__InsufficientUserBalance();
    error PasarEscrow__TransferFailed();
    
    //////////////////////
    // State Variables  // 
    //////////////////////

    enum OrderStatus {
        NOTCREATED,
        LOCKED,
        DISPUTED,
        RELEASED,
        REFUNDED
    } 

    struct OrderDetails {
        bytes32 orderId;
        address buyer;
        address token;
        uint256 amount;  
        OrderStatus status;
    }

    mapping (bytes32 => OrderDetails) private s_orders;

    address private s_platformTreasury;

    //////////////////////
    // Events           // 
    //////////////////////

    event FundsLocked(bytes32 indexed orderId, address indexed buyer, address indexed token, uint256 amount);
    event FundsReleasedToCryptoSeller(bytes32 indexed orderId, address indexed seller);
    event FundsReleasedToPlatformForFiat(bytes32 indexed orderId, bytes32 indexed sellerIdHash);
    event FundsRefunded(bytes32 indexed orderId, address indexed buyer);
    event OrderDisputed(bytes32 indexed orderId);

    //////////////////////
    // Modifiers        //
    ////////////////////// 

    modifier onlyBuyer(bytes32 _orderId){
        if(msg.sender != s_orders[_orderId].buyer){
            revert PasarEscrow__ThisUserIsNotTheBuyer();
        }
        _;
    }
    // modifier orderExists(bytes32 _orderId){ {
    //     if(s_orders[_orderId].status == OrderStatus.NOTCREATED){
    //         revert PasarEscrow__OrderDoesNotExist();
    //     }
    //     _;
    // }

    //////////////////////
    // Functions        //
    //////////////////////
    constructor(address platformTreasury) Ownable(msg.sender){
        if(platformTreasury == address(0)){
            revert PasarEscrow__InvalidTreasuryAddress();
        }
        s_platformTreasury = platformTreasury;
        // s_orders[bytes32(0)]= OrderStatus.NOTCREATED;
    }

    //////////////////////////
    // External Functions   // 
    //////////////////////////
    
    function lockFunds(bytes32 _orderId, uint256 _amount, address _token) external nonReentrant{
        OrderDetails storage order = s_orders[_orderId];
        uint256 balance = msg.sender.balance;
        if(order.status == OrderStatus.NOTCREATED){
            revert PasarEscrow__OrderAlreadyExists();
        }
        if(_amount < 0){
           revert PasarEscrow__MustBeGreaterThanZero();
        }
        if(_amount > balance){
            revert PaserEscrow__InsufficientUserBalance();
        }
        
        s_orders[_orderId] = OrderDetails(_orderId, msg.sender,_token,_amount, OrderStatus.LOCKED); 

        bool success = IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        if(!success){
            revert PasarEscrow__TransferFailed();
        }

        emit FundsLocked(_orderId, msg.sender, _token, _amount);
    }

  function releaseFundsToCryptoSeller(bytes32 _orderId,address _sellerCryptoAddress) external onlyOwner /*orderExists(_orderId)*/ nonReentrant {
        OrderDetails storage order = s_orders[_orderId];
        // if (order.buyer == address(0)) {
        //     revert PasarEscrow__OrderDoesNotExist();
        // }
        if(order.status != OrderStatus.LOCKED){
            revert PasarEscrow__OrderNotLocked();
        }

        order.status = OrderStatus.RELEASED;
        bool success = IERC20(order.token).transfer(_sellerCryptoAddress, order.amount);
        if(!success){
            revert PasarEscrow__TransferFailed();
        }

        emit FundsReleasedToCryptoSeller(_orderId, _sellerCryptoAddress);
    }

    function releaseFundsToPlatformForFiatSeller(
        bytes32 _orderId,
        bytes32 _sellerIdHash
    ) external onlyOwner /*orderExists(_orderId)*/ nonReentrant {
        OrderDetails storage order = s_orders[_orderId];
        if(order.status != OrderStatus.LOCKED){
            revert PasarEscrow__OrderNotLocked();
        }
        
        order.status = OrderStatus.RELEASED;
        bool success = IERC20(order.token).transfer(s_platformTreasury, order.amount);
        if(!success){
            revert PasarEscrow__TransferFailed();
        }

        emit FundsReleasedToPlatformForFiat(_orderId, _sellerIdHash);
    }

    function initiateDispute(bytes32 _orderId)
        external
        onlyBuyer(_orderId)
        /*orderExists(_orderId)*/
    {
        OrderDetails storage order = s_orders[_orderId];
        
        if(order.status != OrderStatus.LOCKED){
            revert PasarEscrow__CannotDisputeOrder();
        }

        order.status = OrderStatus.DISPUTED;

        emit OrderDisputed(_orderId);
    }

    function refundBuyer(bytes32 _orderId)
        external
        onlyOwner
        /*orderExists(_orderId)*/
        nonReentrant
    {
        OrderDetails storage order = s_orders[_orderId];

        if(order.status != OrderStatus.LOCKED && order.status != OrderStatus.DISPUTED){
            revert PasarEscrow__OrderNotLocked();
        }

        order.status = OrderStatus.REFUNDED;
        bool success = IERC20(order.token).transfer(order.buyer, order.amount);
        if(!success){
            revert PasarEscrow__TransferFailed();
        }

        emit FundsRefunded(_orderId, order.buyer);
    }

    
}