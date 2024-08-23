// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AggregatorV3Interface} from "@chainlink/shared/interfaces/AggregatorV3Interface.sol";

contract ChainlinkPriceOracleAdapter is IPriceOracle {
    using SafeCast for int256;

    AggregatorV3Interface public immutable DATA_FEED;

    constructor(AggregatorV3Interface _dataFeed) {
        DATA_FEED = _dataFeed;
    }

    // Returns the price of the 1 full unit of PaymentToken expressed in USD using 8 decimal points.
    // If there is any error or stale data, this method should revert the entire transaction.
    function getPaymentTokenPrice() external view override returns (uint256 price) {
        /**
         * If data feeds are read on L2 networks, then the latest answer from the
         * L2 Sequencer Uptime Feed must be checked to ensure that the data is accurate in the event
         * of an L2 sequencer outage.
         * https://docs.chain.link/data-feeds/l2-sequencer-feeds
         */
        (, int256 answer,,,) = DATA_FEED.latestRoundData();
        return answer.toUint256();
    }
}
