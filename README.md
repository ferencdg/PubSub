# ServiceRegistry

## High level design

The solution I submit intends to charge subscribers per second for the usage of the services. It also aims to minimize gas usage by borrowing concepts from staking and slashing. The solution works for any number of service providers. The solution can also be modified to allow changing service fees. The following 3 concepts help minimize gas cost.

### 1. Concepts from staking

Similarly to staking contracts, the ServiceRegistry contract's state only changes when either subscribers or providers interact with the contract. As part of the state change we calculate the balance changes both for the subscriber and/or for the provider using the current time and the time since the last interaction with the contract.

### 2. Concepts from slashing

Competing offchain slashers monitor and recalculates the subscribers' balance every 1 minute and when a subscriber's balance falls below a predefined threshold, the slashers call the ServiceRegistry's slash() method. It is important to say that the balance here is the calculated balance which equals to the stored balance minus all the service fees that has not yet been subtracted from the subscriber's stored balance due to lack of contract interaction.

Upon calling the slash() method, it updates the stored balance for the subscriber (and for the provider) and if the new stored balance if indeed below the threshold, then automatically unsubscribes from all providers and send the remaining balance to the slasher. During the automatic unsubscriptions the subscriber count stored in the providers is decreased by one. This makes sure that insolvent subscribers won't allow providers to withdraw more tokens from the ServiceRegistry than they are entitled to. In fact the main reason for slashing is to decrease these subscriber counts.

### 3. Refunds for subscribing to suspended providers

Suspended providers are tracked offchain by wallets or defi apps and submitted alongside with state changing operations, for example:

function subscribeToProvider(bytes32 subscriberId, bytes32 providerId, bytes32[] calldata suspendedProviderIds)

The suspendedProviderIds array can contain providers that a particular subscriberId is subscribed to and since then had been suspended. By submitting that array, the subscriber can get a refund between the period of [providerSuspendedTime, now]. It is worth mentioning that slasher are not incentivized to provide a list of suspendedProviderIds when calling the slash method as they hope that the calculated balance will fall below the threshold.

ServiceRegistry contract could work without suspendedProviderIds array as well and could provide refunds. However this would require the ServiceRegistry contract to iterate through all the subscriptions for a particular user to check the status of those providers.

###

## Limitations and comments

### Suspending providers

In the current solution the suspension of providers is supported, however reactivating them is not supported. In order to support reactivation, the ServiceRegistry should maintain a full history of all the suspension and reactivation of the said provider. The history should include the timestamp of the suspension and reactivation. That way the ServiceRegistry could give a refund for those periods where the service was suspended.

### Changing provider fees

Similarly to suspending providers, this problem can be solved by storing a full history of

### Suspending subscription

Suspending subscription is simply implemented by removing it from the Subscriber's subscription list.

### Events

Events are currently not emitted, and should be added later.

### Tests and Bugs

Tests are currently not added, and the code most probably contains major bugs due to rushed development.

### Each provider has a list of Subscribers

The problem description implies that providers should maintain a list of Subscribers. However that list is never used, and storing just the subscriber count is sufficient. For the sake of gas efficiency, I didn't add a list of subscribers to the provider, but can be easily added later.

### Using EnumerableSet.Bytes32Set to store the providers for each subscriber

Originally I planned to iterate through all the subscriptions of a particular subscriber to account for the suspended providers. Later I changed to design to rely on offchain components providing suspendedProviderIds, so I don't necessarily need to iterate through the list, so a simple Set might be sufficient.

However during slashing - as I mentioned earlier - slashers are not incentivized to provide a list of suspendedProviderIds, so during slashing we do have to iterate through the subscriptions, hence it is worth keeping EnumerableSet.Bytes32Set.
