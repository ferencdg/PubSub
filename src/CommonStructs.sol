// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

enum ProviderStatus {
    ACTIVE,
    SUSPENDED
}

struct Provider {
    address owner;
    bytes32 id;
    uint256 serviceFeePerSecond;
    uint256 subscriberCount;
    uint256 pendingFees; // fees that are pending and not yet has been sent to the provider
    uint256 feesCollected; // fees that has already been sent to the provider
    uint256 lastUpdated; // last time this data structure was updated
    ProviderStatus status;
    uint256 suspensionTime;
}

struct Subscriber {
    address owner;
    bytes32 id;
    uint256 balance;
    EnumerableSet.Bytes32Set subscriptions;
    uint256 serviceFeePerSecondForAllSubscrions;
    uint256 lastUpdated;
}

// return value of getProviderData function
struct ProviderRet {
    address owner;
    uint256 serviceFeePerSecond;
    uint256 subscriberCount;
    uint256 pendingFees;
    ProviderStatus status;
}

// return value of getSubscriberData function
struct SubscriberRet {
    address owner;
    uint256 balance;
    bytes32[] subscriptions;
}
