
// SPDX-License-Identifier: MIT





/*
*@title OracleLib.sol
*@author Adebakin Olujimi
*@notice This library provides functions to interact with the price feed of collateral tokens in the SXCEngine.
*@dev It includes functions to get the price of a collateral token in USD and to update the
*@notice if a price is stale, the function will revert and render the SXCEngine unusable - this is by design, and we want to ensure that the price feed is always up-to-date.
*@dev This library is used by the SXCEngine to ensure that collateral prices are up-to-date and accurate.
*@dev The library is designed to be used with the SXCEngine contract and is not intended
so if the chainlink network explodes and you have a lot of collateral tokens, this library will not be able to handle it.
*/

// library OracleLib {

//       error OracleLib_StalePrice();

//       uint256 private constant TIMEOUT  = 3 hours; // 3 hours timeout for price feed updates

//       function stalePriceCheckLatestRoundData(AggregatorV3Interface priceFeed) public view returns (uint88, int256, uint256, uint80){
//             (
//                   uint80 roundId,
//                   int256 price,
//                   uint256 startedAt,
//                   uint80 answeredInRound
//             ) = priceFeed.latestRoundData();

//             uint256 secondSince = block.timestamp - startedAt;
//             if (secondsSince > TIMEOUT) {
//                   revert OracleLib_StalePrice();
//             }
//             return (roundId, price, startedAt, answeredInRound);

//             // require(answeredInRound >= roundId, "OracleLib: Price is stale or invalid");

//             // return (roundId, price, startedAt, answeredInRound);
//       }

//       function stalePriceCheck(int256 price) internal pure {
//             require(price > 0, "OracleLib: Price is stale or invalid");
//       }
// }


pragma solidity ^0.8.26;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";


library OracleLib {
    error OracleLib__StalePrice();
    error OracleLib__InvalidPrice();

    /// @dev Timeout after which price feed is considered stale - (3 hours)
    uint256 private constant TIMEOUT = 3 hours;

    /*
     * @notice Safely gets the latest price from a Chainlink feed
     * @author Adebakin Olujimi
     * @dev This function checks if the price is stale or invalid before returning it
     * @dev Reverts if the price is stale or invalid
     * @param priceFeed The Chainlink AggregatorV3Interface
     * @return price The most recent safe price
     */
    function stalePriceCheckLatestRoundData(AggregatorV3Interface priceFeed) internal view returns (uint256 price) {
        (
            uint80 roundID,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        // Validate price freshness
        if (updatedAt == 0 || updatedAt + TIMEOUT < block.timestamp) {
            revert OracleLib__StalePrice();
        }

        // Validate Chainlink feed round data integrity
        if (answeredInRound < roundID) {
            revert OracleLib__StalePrice(); // could also use a distinct error
        }

        // Validate price positivity
        if (answer <= 0) {
            revert OracleLib__InvalidPrice();
        }

        return uint256(answer);
    }
}