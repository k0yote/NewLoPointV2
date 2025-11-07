# Release v0.1.0 - Initial Beta Release

## 🎉 Overview

This is the first beta release of the NewLo JPYC Cross-Chain Bridge, enabling NLP to JPYC exchanges between Soneium and Polygon chains.

## ✨ Features

### Core Bridge Functionality
- **Cross-chain NLP to JPYC exchange** with automatic failure recovery
- **Dual protocol support**: LayerZero V2 and Chainlink CCIP implementations
- **Lock/Unlock/Burn pattern** for secure token handling
- **Bidirectional messaging** for atomicity guarantees

### JPYC Management (PR #2)
- **depositWithPermit**: EIP-2612 gasless approval for single-transaction deposits
  - 40% gas reduction (111k → 66k gas)
  - Better UX with off-chain signatures

- **ReceiverV2**: Self-custody receivers without JPYCVault dependency
  - Simpler architecture
  - No EXCHANGE_ROLE management needed
  - Direct JPYC transfers with detailed error reporting

## 📦 Smart Contracts

### Soneium Chain
- `NLPMinterBurner.sol` - Authorized NLP burner
- `NLPOAppAdapter.sol` - LayerZero OApp adapter
- `NLPCCIPAdapter.sol` - Chainlink CCIP adapter

### Polygon Chain
- `JPYCVault.sol` - JPYC liquidity pool with depositWithPermit
- `NLPOAppJPYCReceiver.sol` - LayerZero receiver (V1)
- `NLPCCIPJPYCReceiver.sol` - CCIP receiver (V1)
- `NLPOAppJPYCReceiverV2.sol` - LayerZero receiver (V2, self-custody)
- `NLPCCIPJPYCReceiverV2.sol` - CCIP receiver (V2, self-custody)

## 🧪 Testing

- **35 comprehensive tests** covering all functionality
- **Integration tests** for full cross-chain flows
- **Unit tests** for individual contracts
- All tests passing ✅

## 📚 Documentation

- [ARCHITECTURE.md](./ARCHITECTURE.md) - System architecture with sequence diagrams
- [DEPOSIT_GUIDE.md](./DEPOSIT_GUIDE.md) - JPYC deposit operations (3 methods)
- [RECEIVER_V2_GUIDE.md](./RECEIVER_V2_GUIDE.md) - V2 receiver deployment guide
- [SECURITY_AUDIT.md](./SECURITY_AUDIT.md) - Security audit results

## 🔧 Development Tools

- **Foundry scripts** for deployment
- **TypeScript examples** for integration
- **Shell scripts** for operations
- **Comprehensive test suite**

## ⚠️ Important Notes

### Before Mainnet Deployment

- [ ] Complete professional security audit
- [ ] Deploy to testnets and verify end-to-end flows
- [ ] Use multisig wallets for all admin/owner addresses
- [ ] Ensure sufficient JPYC liquidity
- [ ] Fund receivers with native tokens for responses
- [ ] Monitor LayerZero/CCIP transaction status

### Known Limitations

- This is a **beta release** for testing purposes
- Recommended for testnet deployment only
- Production deployment requires additional security review

## 🔗 Links

- **Repository**: https://github.com/k0yote/NewLoPointV2
- **Documentation**: See README.md and docs folder
- **Issues**: https://github.com/k0yote/NewLoPointV2/issues

## 🙏 Contributors

- @k0yote - Initial implementation and architecture
- Claude Code - Development assistance

## 📝 Changelog

### Added
- Cross-chain bridge contracts (LayerZero & CCIP)
- JPYCVault with depositWithPermit (EIP-2612)
- ReceiverV2 contracts (self-custody)
- Comprehensive test suite (35 tests)
- Deployment scripts and examples
- Complete documentation

### Changed
- Updated foundry.toml with via_ir for stack depth resolution

### Fixed
- N/A (initial release)

## 🔜 Next Steps

- [ ] Deploy to Soneium testnet
- [ ] Deploy to Polygon testnet
- [ ] End-to-end testing on testnets
- [ ] Community feedback collection
- [ ] Professional security audit
- [ ] Mainnet deployment preparation

---

**Full Changelog**: https://github.com/k0yote/NewLoPointV2/commits/v0.1.0
