# 🚀 SuiGas Protocol - Smart Contracts

<div align="center">
  <h3>Decentralized Gas Futures Trading Smart Contracts on Sui Network</h3>
  
  [![Sui Network](https://img.shields.io/badge/Built%20on-Sui%20Network-00D4FF?style=for-the-badge)](https://sui.io)
  [![Move Language](https://img.shields.io/badge/Language-Move-FF6B35?style=for-the-badge)](https://move-language.github.io/move/)
  [![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)
</div>

## 🌟 Overview

SuiGas Protocol smart contracts implement a comprehensive decentralized gas futures trading platform on the Sui blockchain. The protocol enables users to trade gas price futures, provide liquidity, participate in governance, and earn yield through various DeFi mechanisms.

## 📋 Contract Architecture

### Core Contracts

| Contract                   | Description                           | Lines of Code |
| -------------------------- | ------------------------------------- | ------------- |
| **`gas_futures.move`**     | Gas futures trading core logic        | 495           |
| **`amm.move`**             | Automated Market Maker implementation | 552           |
| **`oracle.move`**          | Price oracle and data feeds           | 455           |
| **`risk_management.move`** | Risk assessment and mitigation        | 410           |
| **`enhanced_risk.move`**   | Advanced risk management features     | 607           |

### Governance & Tokenomics

| Contract                  | Description                            | Lines of Code |
| ------------------------- | -------------------------------------- | ------------- |
| **`gfs_governance.move`** | Governance token and voting mechanisms | 533           |
| **`presale.move`**        | Token presale implementation           | 199           |
| **`yield_farming.move`**  | Staking and yield farming rewards      | 643           |

### Enterprise Features

| Contract              | Description                                   | Lines of Code |
| --------------------- | --------------------------------------------- | ------------- |
| **`enterprise.move`** | Enterprise solutions and white-label features | 436           |

## 🏗️ Key Features

### 🔥 Gas Futures Trading

- **Multiple Expiration Dates** - Weekly, monthly, and quarterly futures
- **Automated Settlement** - Oracle-based price settlement
- **Margin Trading** - Leveraged positions with risk management
- **Position Management** - Advanced order types and risk controls

### 💱 Automated Market Maker (AMM)

- **Constant Product Formula** - Uniswap V2 style AMM
- **Dynamic Fees** - Adaptive fee structure based on volatility
- **Liquidity Incentives** - LP token rewards and yield farming
- **Slippage Protection** - Maximum slippage controls

### 🔮 Oracle System

- **Multiple Price Sources** - Aggregated gas price feeds
- **Chainlink Integration** - External price data validation
- **Fallback Mechanisms** - Redundant price sources
- **Price Manipulation Protection** - TWAP and circuit breakers

### 🛡️ Risk Management

- **Portfolio Risk Assessment** - Real-time risk calculations
- **Liquidation Engine** - Automated position liquidation
- **Insurance Fund** - Protocol insurance for extreme events
- **Emergency Pause** - Circuit breakers for market stress

### 🏛️ Governance

- **GFS Token Voting** - Decentralized governance decisions
- **Proposal System** - Community-driven protocol upgrades
- **Treasury Management** - Protocol fee distribution
- **Parameter Updates** - Dynamic protocol configuration

## 🚀 Getting Started

### Prerequisites

- **Sui CLI** - Install from [Sui Documentation](https://docs.sui.io/build/install)
- **Move Compiler** - Included with Sui CLI
- **Git** - Version control

### Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/deepgas-protocol.git
cd deepgas-protocol

# Verify Move.toml configuration
cat Move.toml
```

### Building Contracts

```bash
# Compile all contracts
sui move build

# Run tests
sui move test

# Check for compilation errors
sui move build --lint
```

### Testing

```bash
# Run all tests
sui move test

# Run specific test module
sui move test --filter gas_futures

# Run tests with coverage
sui move test --coverage
```

## 📋 Deployment

### Mainnet Deployment

Current mainnet deployment addresses:

```toml
[addresses]
gfs_token = "0x..."
amm_pool = "0x..."
gas_futures = "0x..."
oracle = "0x..."
governance = "0x..."
risk_manager = "0x..."
yield_farm = "0x..."
enterprise = "0x..."
presale = "0x..."
```

### Deploy to Network

```bash
# Deploy to testnet
sui client publish --gas-budget 100000000

# Deploy to mainnet (requires mainnet configuration)
sui client switch --env mainnet
sui client publish --gas-budget 200000000
```

### Verify Deployment

```bash
# Check deployed objects
sui client objects

# Verify contract functionality
sui client call --package <PACKAGE_ID> --module gas_futures --function get_market_info
```

## 🔧 Configuration

### Move.toml

```toml
[package]
name = "deepgas_protocol"
version = "1.0.0"
edition = "2024.beta"

[dependencies]
Sui = { git = "https://github.com/MystenLabs/sui.git", subdir = "crates/sui-framework/packages/sui-framework", rev = "framework/mainnet" }

[addresses]
deepgas_protocol = "0x0"
```

### Environment Setup

```bash
# Set up Sui client for testnet
sui client new-env --alias testnet --rpc https://fullnode.testnet.sui.io:443

# Set up for mainnet
sui client new-env --alias mainnet --rpc https://fullnode.mainnet.sui.io:443

# Switch environments
sui client switch --env testnet
```

## 🧪 Testing Framework

### Unit Tests

Each contract includes comprehensive unit tests:

```move
#[test]
public fun test_create_gas_futures_position() {
    // Test implementation
}

#[test]
public fun test_amm_swap_calculation() {
    // Test implementation
}

#[test]
public fun test_oracle_price_update() {
    // Test implementation
}
```

### Integration Tests

Cross-contract interaction tests:

```move
#[test]
public fun test_complete_trading_flow() {
    // End-to-end trading test
}

#[test]
public fun test_liquidation_scenario() {
    // Risk management integration test
}
```

## 📊 Gas Optimization

### Performance Metrics

| Contract    | Deploy Gas | Avg Function Gas |
| ----------- | ---------- | ---------------- |
| Gas Futures | ~2.5M      | ~50K             |
| AMM         | ~3.2M      | ~75K             |
| Oracle      | ~1.8M      | ~30K             |
| Governance  | ~4.1M      | ~100K            |

### Optimization Techniques

- **Struct Packing** - Efficient data structure layout
- **Batch Operations** - Multiple operations in single transaction
- **Lazy Evaluation** - Compute values only when needed
- **Storage Optimization** - Minimal on-chain storage

## 🔒 Security

### Security Features

- **Access Control** - Role-based permissions
- **Reentrancy Protection** - Guard against recursive calls
- **Integer Overflow Protection** - Safe arithmetic operations
- **Emergency Pause** - Circuit breakers for critical functions

### Audit Status

- ✅ **Internal Security Review** - Completed
- 🔄 **External Audit** - In Progress
- 📋 **Bug Bounty Program** - Active

### Security Best Practices

- **Principle of Least Privilege** - Minimal required permissions
- **Input Validation** - Comprehensive parameter checking
- **Error Handling** - Graceful failure modes
- **Monitoring** - Event emission for tracking

## 📈 Protocol Economics

### Tokenomics

- **Total Supply**: 1,000,000,000 GFS
- **Presale**: 200,000,000 GFS (20%)
- **Liquidity**: 150,000,000 GFS (15%)
- **Team**: 100,000,000 GFS (10%) - 2 year vesting
- **Development**: 200,000,000 GFS (20%) - 3 year vesting

### Fee Structure

- **Trading Fees**: 0.3% per transaction
- **AMM Fees**: 0.25% for liquidity providers
- **Governance Fees**: 0.1% for protocol treasury
- **Enterprise Fees**: Custom pricing

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guidelines](CONTRIBUTING.md).

### Development Workflow

1. **Fork** the repository
2. **Create** a feature branch
3. **Write** comprehensive tests
4. **Follow** Move coding standards
5. **Submit** a pull request

### Code Standards

- **Move Style Guide** - Follow official Move conventions
- **Documentation** - Comprehensive inline comments
- **Testing** - 90%+ test coverage
- **Security** - Security-first development

## 📖 Documentation

### Resources

- **Move Language Book**: [move-book.com](https://move-book.com)
- **Sui Documentation**: [docs.sui.io](https://docs.sui.io)
- **Protocol Whitepaper**: [suigas.xyz/whitepaper](https://suigas.xyz/whitepaper)
- **API Reference**: [docs.suigas.xyz](https://docs.suigas.xyz)

### Examples

```move
// Create a gas futures position
public fun create_position(
    market: &mut GasFuturesMarket,
    amount: u64,
    leverage: u8,
    is_long: bool,
    ctx: &mut TxContext
): Position {
    // Implementation
}

// Provide AMM liquidity
public fun add_liquidity(
    pool: &mut AMMPool,
    token_a_amount: u64,
    token_b_amount: u64,
    ctx: &mut TxContext
): LPToken {
    // Implementation
}
```

## 📞 Support

### Community

- **Discord**: [Join Community](https://discord.gg/suigas)
- **Twitter**: [@suigas](https://twitter.com/suigas)
- **Telegram**: [SuiGas Protocol](https://t.me/suigas)
- **Email**: dev@suigas.xyz

### Issues

- **Bug Reports**: Use GitHub Issues
- **Feature Requests**: GitHub Discussions
- **Security Issues**: security@suigas.xyz

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## ⚠️ Disclaimer

This software is experimental and unaudited. Use at your own risk. The protocol is provided "as is" without warranty of any kind. Trading involves risk of loss.

---

<div align="center">
  <p><strong>Built with Move on Sui Network</strong></p>
  <p>© 2024 SuiGas Protocol. All rights reserved.</p>
</div>
