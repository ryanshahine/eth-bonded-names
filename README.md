# eth-bonded-names
A refundable, yield-generating alternative to rental-based name systems like ENS.

## Overview and motivation

ETH Bonded Names is an experimental Ethereum name registry that replaces the rental model used by ENS with a refundable bond model.

ENS requires users to pay recurring registration fees. If the user does not renew, the name expires. This design means the economic relationship between a user and a name is fundamentally rental-based. A model seen in traditional TLDs, where users pay a yearly fee to maintain ownership of a domain name. Arguably, ENS is not a credible neutral name ownership system, but rather a name rental business.

Beyond ENS’s network effects, NFT speculation, and historical importance, the ENS economic model is inferior for many name ownership use cases. 

ETH Bonded Names uses a different model. A user registers a name by locking ETH into the registry. That ETH is deployed into a yield strategy, where it can earn yield while the name is held. The yield is split between the registry and the user. The name remains assigned to the user while the ETH remains bonded. If the user releases the name, the bonded position is withdrawn and the name becomes available again.

## Core model

A name is registered by bonding ETH.

The amount of ETH required is based on a USD-denominated pricing schedule. The contract uses an ETH/USD oracle to calculate the required ETH amount at registration time.

Once the name is registered, the bonded ETH is deployed into a yield strategy. In this example, we are using Lido. Lido is one example strategy, where ETH is converted into wstETH. Aave or another ETH-denominated yield strategy could also be used. The registry design should not depend permanently on a specific yield provider.

The name remains owned by the registrant while the bonded position remains locked.

There is no expiration and no renewal.

If the user releases the name, the name becomes available again and the user withdraws the bonded position.

### Constructor arguments
```solidity
ethUsdFeedAddress      = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
wstEthAddress          = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0
withdrawalQueueAddress = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1
maxOracleStaleness     = 86400
```

## Pricing

The pricing model is intentionally simple.

1 character  = $10,000 bond
2 characters = $1,000 bond
3 characters = $100 bond
4+ characters = $10 bond

The prices are denominated in USD, but paid in ETH. Chainlink provides an ETH/USD oracle that the contract uses to calculate the required ETH amount at registration time.

For example, if ETH trades at $2,500 and a normal name requires a $10 bond, the required deposit is:

$10 / $2,500 = 0.004 ETH

The contract stores the ETH amount deposited at registration time.

The withdrawal is ETH-based, not USD-based. If a user bonds 0.004 ETH, the registry accounts for that ETH-denominated position. The user is not promised a future USD value.

## Other design decisions

### Why not use ENS-style reserve and commit-reveal?

ENS uses a commit-reveal process to prevent mempool frontrunning during registration.

The basic problem is that if a user submits a transaction containing register("name"), another participant can see the name in the public mempool and attempt to register it first with a higher priority fee. ENS solves this by requiring the user to first submit a commitment hash, wait for a minimum period, and then reveal the name in a second transaction.

This repository intentionally does not use that model in the initial design.

The reason is that the expected threat model is different. In modern Ethereum name markets, the more relevant problem is often not someone manually frontrunning a visible registration transaction. The more relevant problem is automated monitoring of availability, short names, popular words, and newly released names. Commit-reveal helps with mempool sniping, but it does not prevent participants from monitoring availability and competing to register valuable names as soon as they become available.

If a deployment needs stronger protection for high-value names, it can add a commit-reveal flow or auction mechanism later. The absence of commit-reveal is a deliberate simplification, not an assumption that frontrunning is impossible.

### Why not use ENS-style hashes internally?

The registry can use:

```solidity
mapping(string => NameRecord) public records;
```

instead of:

```solidity
mapping(bytes32 => NameRecord) public records;
```

Using bytes32 keys is slightly more gas-efficient, but for this registry the difference is not strategically important. Names are short, registration is not a high-frequency action, and transaction costs are not the primary bottleneck - although they used to be, back in the early days of Ethereum. The readability and simplicity of direct string storage are more important for this experiment.

The contract does not need an offchain database to recover a string from a hash. The name is the key.

### On Primary names

The registry supports primary names.

A primary name maps an address to a preferred name:

```solidity
mapping(address => string) public primaryName;
```

This allows applications to resolve an address back to a human-readable name.

The registry does not maintain an onchain mapping from owner to all names. That would require an array inside a mapping, which creates unnecessary cleanup and gas problems when names are transferred or released.

The canonical onchain mapping is:

```solidity
mapping(string => NameRecord) public records;
```

Applications that need owner-to-name enumeration can derive it from events.

### Name validation

The namespace is intentionally restricted.

Allowed characters:
```
a-z
0-9
-
```

Invalid names include:

```
uppercase names
unicode names
names with spaces
names with special characters
names starting with a hyphen
names ending with a hyphen
names containing a double hyphen
names longer than 15 characters
```

This avoids casing ambiguity, Unicode spoofing, and normalization complexity.

### Contract properties

The intended contract design is minimal.

The registry is not upgradeable. It is not ownable. It has no privileged admin role. Core parameters are fixed at deployment.

This is important because a name registry should not depend on an upgrade key or administrative discretion. If users are expected to bond capital into the registry, the rules should be stable and inspectable.

### Status

This repository is experimental.

It is not presented as a complete replacement for ENS infrastructure, resolver standards, subdomain management, or the existing ENS social layer.

It is a focused experiment around one question:

Can Ethereum names use refundable, yield-generating bonds instead of recurring rent?