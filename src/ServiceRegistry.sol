// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {Provider, ProviderRet, ProviderStatus, Subscriber, SubscriberRet} from "./CommonStructs.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ServiceRegistry is Ownable2StepUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // Usd returned from price oracles like Chainlink/Redstone is converted into
    // 8 decimals in the respective price oracle adapters.
    uint256 constant MINIMUM_DEPOSIT_FOR_NEW_SUBSCRIBER = 100 * 1e8;

    mapping(bytes32 => Provider) internal providers;
    mapping(bytes32 => Subscriber) internal subscribers;

    IPriceOracle public priceOracle;
    IERC20 public paymentToken;
    address public proxyOwner;

    // preparing for future contract upgrades in case anyone choose to use ServiceRegistry as a base class
    uint256[50] private __gap;

    error Unauthorized();

    error ProviderAlreadyRegistered();
    error ProviderNotRegistered();
    error ProviderSuspended();
    error ProviderNotSuspended();
    error ProviderSubscriptionFeeTooLow();

    error SubscriberAlreadyRegistered();
    error SubscriberNotRegistered();
    error SubscriberBalanceTooLow();
    error SubscriberInitialDepositTooLow();

    error SubscriptionAlreadyRegistered();
    error SubscriptionNotRegistered();

    modifier onlyProxyOwner() {
        require(_msgSender() == proxyOwner, Unauthorized());
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address _contractOwner, address _proxyOwner, IPriceOracle _priceOracle) external initializer {
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        _transferOwnership(_contractOwner);
        proxyOwner = _proxyOwner;
        priceOracle = _priceOracle;
    }

    function _authorizeUpgrade(address) internal override onlyProxyOwner {}

    function changeProxyOwnership(address _newProxyAddress) external onlyProxyOwner {
        // by passing address(0), the proxy update logic can be switched off
        proxyOwner = _newProxyAddress;
    }

    function changePriceOracle(IPriceOracle _priceOracle) external onlyOwner {
        // the price oracle should be changeable even if the proxy update logic is switched off, as
        // we cannot assume that chainlink will forever work as expected
        priceOracle = _priceOracle;
    }

    function registerNewProvider(bytes32 _providerId, uint256 _serviceFeePerSecond) external {
        Provider storage provider = providers[_providerId];
        require(provider.owner != address(0), ProviderAlreadyRegistered());
        require(getPaymentTokenValueInUsd(_serviceFeePerSecond) * 30 days >= 50 * 1e8, ProviderSubscriptionFeeTooLow());
        // there is no need to limit the number of providers to 200, as this solution can handle an unlimited amount of providers

        provider.owner = _msgSender();
        provider.id = _providerId;
        provider.serviceFeePerSecond = _serviceFeePerSecond;
        provider.lastUpdated = block.timestamp;
        provider.suspensionTime = type(uint256).max;
    }

    function registerNewSubscriber(bytes32 _subscriberId, uint256 _depositAmount) external {
        Subscriber storage subscriber = subscribers[_subscriberId];
        require(subscriber.owner != address(0), SubscriberAlreadyRegistered());
        uint256 depositAmountInUsd = getPaymentTokenValueInUsd(_depositAmount);
        require(depositAmountInUsd >= MINIMUM_DEPOSIT_FOR_NEW_SUBSCRIBER, SubscriberInitialDepositTooLow());
        paymentToken.safeTransferFrom(_msgSender(), address(this), _depositAmount);

        subscriber.owner = _msgSender();
        subscriber.id = _subscriberId;
        subscriber.balance = _depositAmount;
        subscriber.lastUpdated = block.timestamp;
    }

    function subscribeToProvider(bytes32 _subscriberId, bytes32 _providerId, bytes32[] calldata _suspendedProviderIds)
        external
    {
        Provider storage provider = providers[_providerId];
        require(provider.owner != address(0), ProviderNotRegistered());
        require(provider.status != ProviderStatus.SUSPENDED, ProviderSuspended());
        Subscriber storage subscriber = subscribers[_subscriberId];
        require(subscriber.owner != address(0), SubscriberNotRegistered());
        require(subscriber.owner == _msgSender(), Unauthorized());
        require(!subscriber.subscriptions.contains(_providerId), SubscriptionAlreadyRegistered());

        updateSubscriberProviderStates(subscriber, provider, _suspendedProviderIds);

        subscriber.serviceFeePerSecondForAllSubscrions += provider.serviceFeePerSecond;
        subscriber.subscriptions.add(_providerId);
        provider.subscriberCount++;
    }

    function unsubscribeFromProvider(
        bytes32 _subscriberId,
        bytes32 _providerId,
        bytes32[] calldata _suspendedProviderIds
    ) external {
        Provider storage provider = providers[_providerId];
        require(provider.owner != address(0), ProviderNotRegistered());
        Subscriber storage subscriber = subscribers[_subscriberId];
        require(subscriber.owner != address(0), SubscriberNotRegistered());
        require(subscriber.owner == _msgSender(), Unauthorized());
        require(subscriber.subscriptions.contains(_providerId), SubscriptionNotRegistered());

        updateSubscriberProviderStates(subscriber, provider, _suspendedProviderIds);

        subscriber.serviceFeePerSecondForAllSubscrions -= provider.serviceFeePerSecond;
        subscriber.subscriptions.remove(_providerId);
        provider.subscriberCount--;
    }

    function updateSubscriberProviderStates(
        Subscriber storage _subscriber,
        Provider storage _provider,
        bytes32[] calldata _suspendedProviderIds
    ) internal {
        bytes32[] memory subscriptionsToRemove;
        uint256 subscriptionsToRemoveLength;

        (_subscriber.balance, _subscriber.lastUpdated, subscriptionsToRemove, subscriptionsToRemoveLength) =
            getSubscriberState(_subscriber, _suspendedProviderIds);

        for (uint256 i; i < subscriptionsToRemoveLength; i++) {
            require(_subscriber.subscriptions.remove(subscriptionsToRemove[i]), SubscriptionNotRegistered());
        }

        // updating provider balance
        _provider.pendingFees = getProviderPendingFees(_provider);
        _provider.lastUpdated = block.timestamp;
    }

    function getSubscriberState(Subscriber storage _subscriber, bytes32[] calldata _suspendedProviderIds)
        internal
        view
        returns (
            uint256 subscriberBalance,
            uint256 subscriberLastUpdated,
            bytes32[] memory subscriptionsToRemove,
            uint256 subscriptionsToRemoveLength
        )
    {
        // Adjust subscriber balance to take into account suspended providers, as the subscriber should not have payed for those since
        // the time the suspension took effect. Special care needs to be taken here, as the subscriber could try to manipulate the suspendedProviderIds
        // to his advantage for example claiming he has subscribed to a provider which has been suspended, but he has never subscribed.
        uint256 suspendedProviderIdsLength = _suspendedProviderIds.length;
        subscriptionsToRemove = new bytes32[](suspendedProviderIdsLength);
        uint256 suscriberBalanceAdjustmentForSuspendedProviders;
        for (uint256 i; i < suspendedProviderIdsLength; i++) {
            Provider storage potentiallySuspendedProvider = providers[_suspendedProviderIds[i]];
            require(potentiallySuspendedProvider.owner != address(0), ProviderNotRegistered());
            // checking for containment is a constant time operation due to using EnumerableSet.Bytes32Set
            require(_subscriber.subscriptions.contains(potentiallySuspendedProvider.id), SubscriptionNotRegistered());
            if (potentiallySuspendedProvider.status == ProviderStatus.SUSPENDED) {
                suscriberBalanceAdjustmentForSuspendedProviders += (
                    block.timestamp - potentiallySuspendedProvider.suspensionTime
                ) * potentiallySuspendedProvider.suspensionTime;
                // cannot remove in this view function, so a list of providers is created and removed later
                subscriptionsToRemove[subscriptionsToRemoveLength] = _suspendedProviderIds[i];
                subscriptionsToRemoveLength++;
            }
        }

        // updating subscriber balance
        // relying on solidity 0.8.0 compiler for integer underflows and overflows
        subscriberBalance = _subscriber.balance + suscriberBalanceAdjustmentForSuspendedProviders
            - (block.timestamp - _subscriber.lastUpdated) * _subscriber.serviceFeePerSecondForAllSubscrions;
        subscriberLastUpdated = block.timestamp;
    }

    function depositPaymentToken(bytes32 _subscriberId, uint256 _tokenAmount) external {
        Subscriber storage subscriber = subscribers[_subscriberId];
        require(subscriber.owner != address(0), SubscriberNotRegistered());

        // anyone can deposit to a particular subscriber, there is no need to restrict it further
        paymentToken.safeTransferFrom(_msgSender(), address(this), _tokenAmount);
        subscriber.balance += _tokenAmount;
    }

    function withdrawSubscriptionFees(bytes32 _providerId, address _recipientAddress) external {
        Provider storage provider = providers[_providerId];
        require(provider.owner != address(0), ProviderNotRegistered());
        require(provider.owner == _msgSender(), Unauthorized());

        _withdrawSubscriptionFees(provider, _recipientAddress);
    }

    function removeProvider(bytes32 _providerId, address _recipientAddress) external {
        Provider storage provider = providers[_providerId];
        require(provider.owner != address(0), ProviderNotRegistered());
        require(provider.owner == _msgSender(), Unauthorized());

        // as mentioned in README.md, the current version of the code only supports
        // ACTIVE -> SUSPENDED transitions, but not SUSPENDED -> ACTIVE
        provider.status = ProviderStatus.SUSPENDED;
        provider.suspensionTime = block.timestamp;
        _withdrawSubscriptionFees(provider, _recipientAddress);
    }

    function _withdrawSubscriptionFees(Provider storage _provider, address _recipientAddress) internal {
        // calculing subscription fees
        uint256 feesToWithdraw = getProviderPendingFees(_provider);
        paymentToken.safeTransfer(_recipientAddress, feesToWithdraw);
        _provider.feesCollected += feesToWithdraw;
        _provider.pendingFees = 0;
        _provider.lastUpdated = block.timestamp;
    }

    function getProviderPendingFees(Provider storage _provider) internal view returns (uint256 pendingFee) {
        pendingFee = _provider.pendingFees
            + (Math.min(block.timestamp, _provider.suspensionTime) - _provider.lastUpdated) * _provider.subscriberCount
                * _provider.serviceFeePerSecond;
    }

    function getProviderData(bytes32 _providerId) external view returns (ProviderRet memory providerRet) {
        Provider storage provider = providers[_providerId];
        require(provider.owner != address(0), ProviderNotRegistered());

        providerRet = ProviderRet(
            provider.owner,
            provider.serviceFeePerSecond,
            provider.subscriberCount,
            getProviderPendingFees(provider),
            provider.status
        );
    }

    // returns the sum of all the fees that has already been retrieved by the provider or currently pending
    function getProviderEarnings(bytes32 _providerId) external view returns (uint256 earnings) {
        Provider storage provider = providers[_providerId];
        require(provider.owner != address(0), ProviderNotRegistered());

        earnings = provider.feesCollected + getProviderPendingFees(provider);
    }

    function getSubscriberData(bytes32 _subscriberId, bytes32[] calldata _suspendedProviderIds)
        external
        view
        returns (SubscriberRet memory subscriberRet)
    {
        Subscriber storage subscriber = subscribers[_subscriberId];
        require(subscriber.owner != address(0), SubscriberNotRegistered());

        (uint256 subscriberBalance,,,) = getSubscriberState(subscriber, _suspendedProviderIds);
        subscriberRet = SubscriberRet(subscriber.owner, subscriberBalance, subscriber.subscriptions._inner._values);
    }

    function getSubscriberDepositValueUsd(bytes32 _subscriberId, bytes32[] calldata _suspendedProviderIds)
        external
        view
        returns (uint256 depositValueUsd)
    {
        Subscriber storage subscriber = subscribers[_subscriberId];
        require(subscriber.owner != address(0), SubscriberNotRegistered());
        (uint256 subscriberBalance,,,) = getSubscriberState(subscriber, _suspendedProviderIds);
        depositValueUsd = getPaymentTokenValueInUsd(subscriberBalance);
    }

    // Returns the price of _pamentTokenAmount expressed in USD using 8 decimal points.
    function getPaymentTokenValueInUsd(uint256 _pamentTokenAmount) internal view returns (uint256 tokenPrice) {
        // Assuming that the paymentToken decimal count is 1e18.
        // This can be queried in the future by calling the decimal() function on the ERC20 token.
        tokenPrice = priceOracle.getPaymentTokenPrice() * _pamentTokenAmount / 1e18;
    }

    // slashing the subscriber if its balance falls below the threshold
    function slashSubscriber(bytes32 _subscriberId, address _recipientAddress) external {
        /*
           1. Check the user's current balance including potential refunds from suspended providers
           2. If the balance falls below the threshold
              2.1 automatically remove all subscriptions for the subscriber
              2.2 update the balances and other data for both the subscriber and
                  the providers that this subscriber previusly subscribed to
              2.3 send the remaining balance to _recipientAddress set by the slasher

           Regarding security
           1. As the slasher iterates through all the subscriptions, a subscriber could prevent slashing by
           adding a huge number of subscriptions, large enough that the transaction cannot
           be placed inside one block. There are multiple solutions for this for example limiting
           the number of subscriptions per subscriber.
           2. There has to be a way to recover from situations where the slash happens too late,
              and now the subscriber balance is negative, as this could prevent some providers from withdrawing.
              One way to solve this issue is to take a fee from all provider earnings that contribute to
              an insurance/recover fund.
        */
    }
}
