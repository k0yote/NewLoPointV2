# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a cross-chain bridge that enables transferring NewLoPoint (NLP) tokens from Soneium to Polygon and exchanging them for JPYC (Japanese Yen Coin). The bridge uses Lock/Unlock/Burn pattern with automatic failure recovery.

**Architecture:** Lock & Exchange with Bidirectional Messaging
- **Soneium (Source):** Locks NLP tokens, sends cross-chain request
- **Polygon (Destination):** Attempts JPYC transfer, sends success/failure response back
- **Automatic Recovery:** On success → Burns locked NLP, On failure → Unlocks NLP back to user

**Both LayerZero V2 and Chainlink CCIP implementations are provided.**

## Key Features

✅ **Automatic Failure Recovery** - No manual intervention needed if JPYC transfer fails
✅ **Bidirectional Messaging** - Response messages ensure atomicity
✅ **Lock/Unlock/Burn Pattern** - Secure and robust token handling
✅ **Direct JPYC Exchange** - No intermediate NLP minting on destination
✅ **Dual Protocol Support** - Both LayerZero and CCIP implementations

## Development Commands

### Build & Test
```bash
# Build contracts
forge build

# Run all tests
forge test

# Run tests with verbose output
forge test -vvv

# Run specific test
forge test --match-contract IntegrationTest
forge test --match-test testSuccessfulExchangeFlow

# Format code
forge fmt

# Gas snapshots
forge snapshot
```

## Architecture

📖 **[View Detailed Architecture with Sequence Diagrams →](./ARCHITECTURE.md)**

### Current Implementation

```
User (Soneium)
    ↓ 1. send(dstEid, recipient, amount)
NLPOAppAdapter / NLPCCIPAdapter
    ↓ 2. Lock NLP tokens
    ↓ 3. Send REQUEST message
LayerZero / CCIP
    ↓ 4. Cross-chain message delivery
NLPOAppJPYCReceiver / NLPCCIPJPYCReceiver
    ↓ 5. Attempt JPYC transfer from JPYCVault
    ↓ 6. Send RESPONSE message (success/failure)
LayerZero / CCIP
    ↓ 7. Response delivery
NLPOAppAdapter / NLPCCIPAdapter
    ↓ 8a. If success → Burn locked NLP
    ↓ 8b. If failure → Unlock NLP back to user
```

### Key Contracts

**Soneium Chain:**
- **NLPMinterBurner**: Authorized contract for burning NLP tokens
- **NLPOAppAdapter**: LayerZero OApp adapter with Lock/Unlock/Burn logic
- **NLPCCIPAdapter**: Chainlink CCIP adapter with Lock/Unlock/Burn logic

**Polygon Chain:**
- **JPYCVault**: JPYC liquidity pool with role-based access control
- **NLPOAppJPYCReceiver**: LayerZero receiver that handles JPYC exchange
- **NLPCCIPJPYCReceiver**: CCIP receiver that handles JPYC exchange

### Message Types

```solidity
enum MessageType {
    REQUEST,   // Soneium → Polygon: Lock NLP, request JPYC
    RESPONSE   // Polygon → Soneium: Success/failure notification
}

struct GiftMessage {
    address recipient;  // Who receives JPYC
    uint256 amount;     // NLP amount locked
}

struct ResponseMessage {
    address user;       // Original sender
    uint256 amount;     // NLP amount
    bool success;       // JPYC transfer succeeded?
}
```

## Deployment

### Option A: LayerZero Deployment

**Phase 1 - Soneium:**
```bash
forge script script/DeployLayerZero.s.sol:DeploySoneiumLayerZero \
  --rpc-url $SONEIUM_RPC --broadcast --verify
```

Deploys:
- NLPMinterBurner
- NLPOAppAdapter

Next steps:
1. Grant MINTER_ROLE to NLPMinterBurner on NLP token
2. Deploy on Polygon

**Phase 2 - Polygon:**
```bash
forge script script/DeployLayerZero.s.sol:DeployPolygonLayerZero \
  --rpc-url $POLYGON_RPC --broadcast --verify
```

Deploys:
- JPYCVault
- NLPOAppJPYCReceiver

Next steps:
1. Fund JPYCVault with JPYC
2. Fund receiver with native tokens for response messages
3. Configure peers

**Phase 3 - Configure Peers:**
```bash
# Run on Soneium
forge script script/DeployLayerZero.s.sol:ConfigureLayerZeroPeers \
  --rpc-url $SONEIUM_RPC --broadcast

# Run on Polygon
cast send $RECEIVER_ADDRESS \
  "setPeer(uint32,bytes32)" \
  $SONEIUM_EID \
  $(cast --to-bytes32 $ADAPTER_ADDRESS) \
  --rpc-url $POLYGON_RPC
```

### Option B: Chainlink CCIP Deployment

**Phase 1 - Soneium:**
```bash
forge script script/DeployCCIP.s.sol:DeploySoneiumCCIP \
  --rpc-url $SONEIUM_RPC --broadcast --verify
```

**Phase 2 - Polygon:**
```bash
forge script script/DeployCCIP.s.sol:DeployPolygonCCIP \
  --rpc-url $POLYGON_RPC --broadcast --verify
```

**Phase 3 - Configure:**
```bash
forge script script/DeployCCIP.s.sol:ConfigureCCIPChains \
  --rpc-url $SONEIUM_RPC --broadcast
```

## User Flow

### Sending NLP from Soneium to Polygon

```typescript
// 1. Approve NLP to adapter
await nlpToken.approve(adapterAddress, amount);

// 2. Send cross-chain (pays LayerZero/CCIP fee)
await adapter.send(
  POLYGON_EID,      // Destination endpoint ID
  recipientAddress, // Who receives JPYC
  amount,          // NLP amount
  "",              // Extra options
  { value: fee }   // Pay cross-chain fee
);

// 3. User's NLP is locked
// 4. LayerZero/CCIP delivers message to Polygon
// 5. Receiver attempts JPYC transfer
// 6. Response sent back:
//    - If success: Locked NLP is burned
//    - If failure: Locked NLP is unlocked back to user
```

## Environment Setup

1. Copy `env.example` to `.env`:
```bash
cp env.example .env
```

2. Fill in required values:
   - `PRIVATE_KEY`: Deployment wallet private key
   - `NLP_TOKEN_ADDRESS`: Existing NewLoPoint contract on Soneium
   - RPC URLs for each chain
   - LayerZero/CCIP endpoint addresses
   - JPYC token addresses

## Operational Notes

### JPYC Liquidity Management

Monitor and replenish vault balance:

```bash
# Check vault balance
cast call $VAULT_ADDRESS "balance()(uint256)" --rpc-url $POLYGON_RPC

# Deposit JPYC into vault
cast send $JPYC_ADDRESS \
  "approve(address,uint256)" \
  $VAULT_ADDRESS \
  $AMOUNT \
  --rpc-url $POLYGON_RPC

cast send $VAULT_ADDRESS \
  "deposit(uint256)" \
  $AMOUNT \
  --rpc-url $POLYGON_RPC
```

### Monitoring Response Messages

The receiver needs native tokens to send response messages back to Soneium:

```bash
# Check receiver balance
cast balance $RECEIVER_ADDRESS --rpc-url $POLYGON_RPC

# Fund receiver if needed
cast send $RECEIVER_ADDRESS \
  --value 1ether \
  --rpc-url $POLYGON_RPC
```

### Security Checklist

**Security Audit Status:**
- [x] Slither static analysis completed - [View Report](./SECURITY_AUDIT.md)
  - All medium-severity issues fixed
  - No high or critical vulnerabilities found

Before mainnet deployment:
- [ ] All admin/owner addresses are multisig wallets
- [ ] MINTER_ROLE on NLP is only granted to NLPMinterBurner
- [ ] NLPMinterBurner only authorizes the adapter as operator
- [ ] JPYCVault EXCHANGE_ROLE only granted to receiver contracts
- [ ] All peers are correctly configured (bidirectional)
- [ ] Receivers are funded with native tokens for responses
- [ ] Complete end-to-end testing on testnets
- [ ] Professional third-party security audit completed

### Common Issues

**Lock fails:**
- Check user has sufficient NLP balance
- Verify user approved adapter

**JPYC transfer fails:**
- Ensure JPYCVault has sufficient JPYC balance
- Check receiver has EXCHANGE_ROLE on vault

**Response not received:**
- Verify receiver has sufficient native tokens
- Check peer is set on both source and destination
- Monitor transaction on LayerZero/CCIP explorer

**Tokens stuck in locked state:**
- This should not happen due to automatic response mechanism
- If it does, it indicates a critical bug requiring investigation

## Testing Strategy

1. **Unit tests**: Test each contract in isolation
2. **Integration tests**: Test full cross-chain flow with mocks
3. **Fork tests**: Test against mainnet state
4. **Testnet deployment**: Full end-to-end flow before mainnet

## Comparison: LayerZero vs Chainlink CCIP

| Feature | LayerZero V2 | Chainlink CCIP |
|---------|-------------|----------------|
| **Fee Payment** | Native | Native or LINK |
| **Security Model** | DVNs + Executor | Oracle network |
| **Supported Chains** | 50+ | 15+ (growing) |
| **Message Delivery** | Optimistic | Finality-based |
| **Gas Efficiency** | Very high | High |
| **Best for** | DeFi, multi-chain | Enterprise apps |

## Resources

- **LayerZero V2 Docs**: https://docs.layerzero.network/v2
- **LayerZero Explorer**: https://layerzeroscan.com
- **Chainlink CCIP Docs**: https://docs.chain.link/ccip
- **CCIP Explorer**: https://ccip.chain.link
