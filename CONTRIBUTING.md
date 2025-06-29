# Contributing to SuiGas Protocol Smart Contracts

Thank you for your interest in contributing to SuiGas Protocol smart contracts! We welcome contributions from the community and are grateful for any help you can provide.

## 🤝 How to Contribute

### Reporting Issues

Before creating an issue, please:
1. **Search existing issues** to avoid duplicates
2. **Use the issue template** if available
3. **Provide detailed information** including:
   - Steps to reproduce the problem
   - Expected vs actual behavior
   - Contract versions and network information
   - Error messages and stack traces

### Suggesting Features

We love feature suggestions! Please:
1. **Check existing feature requests** first
2. **Describe the problem** your feature would solve
3. **Explain your proposed solution** in detail
4. **Consider the impact** on gas costs and security

### Code Contributions

#### Development Setup

1. **Fork the repository**
   ```bash
   git clone https://github.com/yourusername/deepgas-protocol.git
   cd deepgas-protocol
   ```

2. **Install Sui CLI**
   ```bash
   # Follow installation guide at https://docs.sui.io/build/install
   curl -fLJO https://github.com/MystenLabs/sui/releases/download/sui-v1.0.0/sui-ubuntu-x86_64.tgz
   tar -xzf sui-ubuntu-x86_64.tgz
   sudo mv sui /usr/local/bin/
   ```

3. **Verify installation**
   ```bash
   sui --version
   sui move build
   ```

#### Making Changes

1. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes**
   - Follow our coding standards (see below)
   - Write comprehensive tests
   - Update documentation as needed

3. **Test your changes**
   ```bash
   sui move test                    # Run all tests
   sui move test --filter module    # Run specific module tests
   sui move build --lint           # Check for linting issues
   ```

4. **Commit your changes**
   ```bash
   git add .
   git commit -m "feat(module): add amazing new feature"
   ```

5. **Push and create PR**
   ```bash
   git push origin feature/your-feature-name
   ```

## 📋 Coding Standards

### Move Language Standards

- **Follow official Move style guide**
- **Use descriptive variable names**
- **Add comprehensive documentation**
- **Implement proper error handling**

### Function Documentation

```move
/// Creates a new gas futures position with specified parameters
/// 
/// # Arguments
/// * `market` - Mutable reference to the gas futures market
/// * `amount` - Position size in base units
/// * `leverage` - Leverage multiplier (1-10x)
/// * `is_long` - True for long position, false for short
/// 
/// # Returns
/// * `Position` - The created position object
/// 
/// # Panics
/// * If leverage exceeds maximum allowed
/// * If amount is below minimum position size
public fun create_position(
    market: &mut GasFuturesMarket,
    amount: u64,
    leverage: u8,
    is_long: bool,
    ctx: &mut TxContext
): Position {
    // Implementation
}
```

### Struct Documentation

```move
/// Represents a gas futures trading position
/// 
/// # Fields
/// * `id` - Unique position identifier
/// * `owner` - Address of position owner
/// * `amount` - Position size in base currency
/// * `leverage` - Applied leverage multiplier
/// * `entry_price` - Price at position creation
/// * `is_long` - Position direction (long/short)
/// * `created_at` - Timestamp of position creation
public struct Position has key, store {
    id: UID,
    owner: address,
    amount: u64,
    leverage: u8,
    entry_price: u64,
    is_long: bool,
    created_at: u64,
}
```

### Error Handling

```move
/// Error codes for gas futures module
const EInvalidLeverage: u64 = 1;
const EInsufficientBalance: u64 = 2;
const EPositionNotFound: u64 = 3;
const EMarketClosed: u64 = 4;

public fun create_position(/* params */) {
    assert!(leverage >= 1 && leverage <= 10, EInvalidLeverage);
    assert!(amount >= MIN_POSITION_SIZE, EInsufficientBalance);
    // Implementation
}
```

### Testing Standards

```move
#[test]
public fun test_create_valid_position() {
    let scenario = test_scenario::begin(@0x1);
    let ctx = test_scenario::ctx(&mut scenario);
    
    // Setup test environment
    let market = create_test_market(ctx);
    
    // Execute function under test
    let position = create_position(
        &mut market,
        1000,
        2,
        true,
        ctx
    );
    
    // Verify results
    assert!(position.amount == 1000, 0);
    assert!(position.leverage == 2, 1);
    assert!(position.is_long == true, 2);
    
    // Cleanup
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = EInvalidLeverage)]
public fun test_create_position_invalid_leverage() {
    // Test error conditions
}
```

## 🔒 Security Guidelines

### Security Best Practices

- **Input Validation** - Validate all function parameters
- **Access Control** - Implement proper permission checks
- **Integer Overflow** - Use safe arithmetic operations
- **Reentrancy Protection** - Guard against recursive calls

### Security Checklist

Before submitting code, ensure:

- [ ] All inputs are validated
- [ ] Access controls are properly implemented
- [ ] No integer overflow/underflow risks
- [ ] Error conditions are handled gracefully
- [ ] Events are emitted for important state changes
- [ ] Gas usage is optimized
- [ ] Code follows principle of least privilege

### Common Vulnerabilities

```move
// ❌ Bad: No input validation
public fun transfer(amount: u64) {
    // Direct transfer without checks
}

// ✅ Good: Proper validation
public fun transfer(amount: u64) {
    assert!(amount > 0, EInvalidAmount);
    assert!(amount <= MAX_TRANSFER, EAmountTooLarge);
    // Safe transfer logic
}
```

## 🧪 Testing Guidelines

### Test Categories

1. **Unit Tests** - Test individual functions
2. **Integration Tests** - Test contract interactions
3. **Edge Case Tests** - Test boundary conditions
4. **Security Tests** - Test attack vectors

### Test Coverage

- **Aim for 90%+ code coverage**
- **Test all public functions**
- **Test error conditions**
- **Test edge cases and boundaries**

### Performance Testing

```move
#[test]
public fun test_gas_optimization() {
    // Measure gas usage for critical functions
    let gas_before = test_utils::gas_used();
    
    // Execute function
    critical_function();
    
    let gas_after = test_utils::gas_used();
    let gas_used = gas_after - gas_before;
    
    // Assert gas usage is within acceptable limits
    assert!(gas_used <= MAX_ACCEPTABLE_GAS, 0);
}
```

## 🎯 Pull Request Process

### Before Submitting

1. **Ensure code compiles** without warnings
2. **All tests pass** including new tests
3. **Documentation is updated** for new features
4. **Gas optimization** is considered
5. **Security review** is completed

### PR Requirements

- **Clear title** describing the change
- **Detailed description** of implementation
- **Test results** and coverage information
- **Gas usage analysis** for new functions
- **Security considerations** documented

### Review Process

1. **Automated testing** - CI/CD pipeline
2. **Code review** - At least one maintainer
3. **Security review** - Security team review
4. **Gas analysis** - Performance validation
5. **Integration testing** - Full system test

## 📊 Performance Guidelines

### Gas Optimization

- **Minimize storage operations** - Most expensive operations
- **Use efficient data structures** - Optimize for access patterns
- **Batch operations** - Combine multiple operations
- **Avoid unnecessary computations** - Cache when possible

### Storage Optimization

```move
// ❌ Inefficient: Multiple storage operations
public fun update_position(position: &mut Position) {
    position.amount = new_amount;
    position.leverage = new_leverage;
    position.updated_at = timestamp();
}

// ✅ Efficient: Single storage operation
public fun update_position(position: &mut Position, data: PositionUpdate) {
    *position = Position {
        id: position.id,
        owner: position.owner,
        amount: data.amount,
        leverage: data.leverage,
        updated_at: data.timestamp,
        ...*position
    };
}
```

## 🏆 Recognition

Contributors will be recognized through:

- **Contributors list** in README
- **Release notes** for significant contributions
- **Discord contributor role**
- **Protocol governance participation**

## 📞 Getting Help

### Communication Channels

- **Discord**: [SuiGas Development](https://discord.gg/suigas-dev)
- **GitHub Discussions**: Technical questions
- **Email**: dev@suigas.xyz

### Resources

- **Move Language Book**: [move-book.com](https://move-book.com)
- **Sui Documentation**: [docs.sui.io](https://docs.sui.io)
- **Move Examples**: [github.com/MystenLabs/sui/tree/main/examples](https://github.com/MystenLabs/sui/tree/main/examples)

## 🙏 Thank You

Every contribution helps make SuiGas Protocol more secure, efficient, and feature-rich. We appreciate your time and expertise!

---

**Happy Coding! 🚀** 