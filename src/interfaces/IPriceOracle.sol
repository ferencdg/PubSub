// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/* General interface for  accessing data from price oracles. There has to be one or more adaptor contracts
   for example ChainlinkPriceOracleAdapter or RedstonePriceOracleAdapter for each price oracle vendor.
   Those adaptor contracts should all implement the IPriceOracle interface and contain oracle vendor specific code.
   Inside the ServiceRegistry contract the price oracles should be accessed only through the IPriceOracle interface.
*/
interface IPriceOracle {
    // Returns the price of the 1 full unit of PaymentToken expressed in USD using 8 decimal points.
    // If there is any error or stale data, this method should revert the entire transaction.
    function getPaymentTokenPrice() external view returns (uint256 price);
}
