/// Gas Futures Core Contract
/// Allows users to purchase gas credits at fixed prices for future use
module gas_futures::gas_futures {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::table::{Self, Table};
    use sui::balance::{Self, Balance};
    use sui::transfer;
    use std::vector;
    use std::option::{Self, Option};

    // INTEGRATION: Import GAS_CREDITS from AMM module
    use gas_futures::amm::{Self, GAS_CREDITS, GasCreditsRegistry};

    // Error codes
    const E_INVALID_DURATION: u64 = 1;
    const E_INSUFFICIENT_PAYMENT: u64 = 2;
    const E_CONTRACT_EXPIRED: u64 = 3;
    const E_CONTRACT_NOT_FOUND: u64 = 4;
    const E_UNAUTHORIZED: u64 = 5;
    const E_ALREADY_REDEEMED: u64 = 6;
    const E_INSUFFICIENT_GAS_CREDITS: u64 = 7;
    const E_VOUCHER_EXPIRED: u64 = 8;
    const E_INVALID_GAS_AMOUNT: u64 = 9;
    const E_EMERGENCY_MODE: u64 = 10;
    const E_STALE_PRICE: u64 = 11;
    const E_PRICE_DEVIATION_TOO_HIGH: u64 = 12;
    const E_INSUFFICIENT_RESERVES: u64 = 13;
    const E_POSITION_TOO_LARGE: u64 = 14;
    const E_CIRCUIT_BREAKER_ACTIVE: u64 = 15;
    const E_INVALID_AMOUNT: u64 = 3;
    const E_ORACLE_NOT_FOUND: u64 = 16;
    const E_ORACLE_INACTIVE: u64 = 17;
    const E_INVALID_PRICE: u64 = 18;
    const E_INSUFFICIENT_CONFIDENCE: u64 = 19;

    // Contract durations in days
    const DURATION_30_DAYS: u64 = 30;
    const DURATION_60_DAYS: u64 = 60;
    const DURATION_90_DAYS: u64 = 90;

    // Premium rates (basis points)
    const PREMIUM_30_DAYS: u64 = 2500; // 25%
    const PREMIUM_60_DAYS: u64 = 5000; // 50%
    const PREMIUM_90_DAYS: u64 = 8300; // 83%

    // Congestion levels for dynamic pricing
    const CONGESTION_LOW: u8 = 1;
    const CONGESTION_MEDIUM: u8 = 2;
    const CONGESTION_HIGH: u8 = 3;

    // Risk management constants
    const MAX_PRICE_DEVIATION: u64 = 1000; // 10% max price change
    const ORACLE_STALENESS_THRESHOLD: u64 = 300000; // 5 minutes
    const MIN_RESERVE_RATIO: u64 = 2000; // 20% minimum reserves

    // Gas voucher for physical delivery
    public struct GasVoucher has key, store {
        id: UID,
        owner: address,
        credits: u64,
        original_credits: u64,
        expiry: u64,
        created_at: u64,
        redeemed_amount: u64,
        active: bool,
    }

    // Enhanced Sui network gas oracle with external feeds integration
    public struct SuiGasOracle has key {
        id: UID,
        admin: address,
        
        // Primary gas price data
        current_gas_price: u64,
        confidence: u64,
        last_update: u64,
        congestion_level: u8,
        
        // External oracle integration
        external_oracles: Table<vector<u8>, ExternalOracleSource>, // source_name -> oracle
        oracle_source_names: vector<vector<u8>>, // List of configured sources for iteration
        pyth_price_feed_id: Option<vector<u8>>, // Pyth Network feed ID for SUI gas
        chainlink_feed_address: Option<address>, // Chainlink price feed
        
        // Multi-source price aggregation
        price_sources: vector<PriceSourceData>,
        aggregated_price: u64,
        price_weights: Table<vector<u8>, u64>, // source_name -> weight
        
        // Enhanced data storage
        price_history: vector<EnhancedPricePoint>,
        max_history_size: u64,
        twap_1h: u64, // Time-weighted average price 1 hour
        twap_24h: u64, // Time-weighted average price 24 hours
        volatility_24h: u64, // 24-hour volatility measure
        
        // Circuit breaker and validation
        circuit_breaker_active: bool,
        max_price_deviation: u64, // Maximum allowed deviation between sources
        staleness_threshold: u64, // Maximum age for price data
        min_confidence_threshold: u64, // Minimum confidence for price acceptance
        
        // Automated update system
        auto_update_enabled: bool,
        update_frequency: u64, // Minimum time between updates
        validator_reporters: vector<address>, // Authorized validators for price updates
        
        // Emergency fallback
        backup_price: Option<u64>,
        emergency_price_source: Option<address>,
        circuit_breaker_threshold: u64,
    }

    // External oracle source configuration
    public struct ExternalOracleSource has store {
        source_name: vector<u8>, // "pyth", "chainlink", "sui_network", "coingecko"
        oracle_address: Option<address>,
        feed_id: Option<vector<u8>>, // For Pyth Network
        last_price: u64,
        last_update: u64,
        confidence: u64,
        is_active: bool,
        weight: u64, // Weight in price aggregation
        deviation_limit: u64, // Maximum allowed deviation from other sources
    }

    // Enhanced price data with multiple sources
    public struct PriceSourceData has store, drop {
        source_name: vector<u8>,
        price: u64,
        confidence: u64,
        timestamp: u64,
        validation_status: u8, // 1: valid, 2: stale, 3: anomaly, 4: failed
    }

    // Enhanced historical price point
    public struct EnhancedPricePoint has store, drop {
        timestamp: u64,
        price: u64,
        aggregated_price: u64,
        congestion: u8,
        confidence: u64,
        source_count: u64,
        volatility: u64,
        volume: Option<u64>, // Transaction volume if available
    }

    // Gas futures contract structure (enhanced)
    public struct GasFuturesContract has key, store {
        id: UID,
        owner: address,
        gas_credits_amount: u64, // Amount in 9-decimal format  
        gas_credits_coin: Option<Coin<GAS_CREDITS>>, // Actual token storage
        purchase_price: u64,
        expiry_timestamp: u64,
        duration_days: u64,
        status: u8, // 0: active, 1: redeemed, 2: expired
        created_at: u64,
        congestion_at_purchase: u8,
        actual_delivery: bool, // true for physical delivery, false for cash settlement
        voucher_id: Option<ID>,
    }

    // Global state for the gas futures system (enhanced)
    public struct GasFuturesRegistry has key {
        id: UID,
        admin: address,
        total_contracts: u64,
        total_volume: u64,
        total_gas_reserved: u64,
        emergency_mode: bool,
        physical_delivery_enabled: bool,
        gas_reserve_pool: Balance<SUI>,
        contracts: Table<address, vector<ID>>, // user -> contract IDs
        vouchers: Table<address, vector<ID>>, // user -> voucher IDs
        risk_params: RiskParameters,
        total_redeemed: u64,
        active_contracts: u64,
        expired_contracts: u64,
    }

    // NEW: Risk management structure
    public struct RiskParameters has store, drop {
        max_position_size: u64,
        max_total_exposure: u64,
        liquidation_threshold: u64,
        circuit_breaker_threshold: u64,
        min_collateral_ratio: u64,
    }

    // NEW: External Oracle integration
    public struct ExternalOracleConfig has store {
        pyth_price_feed_id: vector<u8>,
        backup_oracle_address: Option<address>,
        price_deviation_limit: u64,
        confidence_threshold: u64,
        update_frequency: u64,
    }

    // NEW: Batch operation structure
    public struct BatchOperation has drop {
        operation_type: u8, // 1: purchase, 2: redeem, 3: use_voucher
        contract_id: Option<ID>,
        voucher_id: Option<ID>,
        amount: u64,
        duration: u64,
        delivery_type: bool,
    }

    // Events (enhanced)
    public struct ContractPurchased has copy, drop {
        contract_id: ID,
        owner: address,
        gas_credits: u64,
        purchase_price: u64,
        expiry_timestamp: u64,
        duration_days: u64,
        physical_delivery: bool,
        congestion_level: u8,
    }

    public struct GasVoucherCreated has copy, drop {
        voucher_id: ID,
        owner: address,
        credits: u64,
        expiry: u64,
        contract_id: ID,
    }

    public struct GasVoucherUsed has copy, drop {
        voucher_id: ID,
        owner: address,
        gas_amount: u64,
        remaining_credits: u64,
        transaction_cost_saved: u64,
    }

    public struct ContractRedeemed has copy, drop {
        contract_id: ID,
        owner: address,
        gas_credits: u64,
        redemption_amount: u64,
        physical_delivery: bool,
        voucher_created: Option<ID>,
    }

    public struct ContractExpired has copy, drop {
        contract_id: ID,
        owner: address,
        gas_credits: u64,
    }

    public struct OracleUpdated has copy, drop {
        old_price: u64,
        new_price: u64,
        price_change_percentage: u64,
        congestion_level: u8,
        confidence: u64,
        timestamp: u64,
    }

    // NEW: Risk management events
    public struct CircuitBreakerActivated has copy, drop {
        timestamp: u64,
        trigger_reason: vector<u8>,
        current_risk_level: u64,
    }

    public struct LiquidationTriggered has copy, drop {
        contract_id: ID,
        owner: address,
        liquidation_amount: u64,
        timestamp: u64,
    }

    // Price point structure
    public struct PricePoint has store {
        timestamp: u64,
        price: u64,
        congestion: u8,
    }

    // Initialize the gas futures system
    fun init(ctx: &mut TxContext) {
        let mut registry = GasFuturesRegistry {
            id: object::new(ctx),
            contracts: table::new(ctx),
            vouchers: table::new(ctx),
            total_contracts: 0,
            total_volume: 0,
            total_gas_reserved: 0,
            gas_reserve_pool: balance::zero<SUI>(),
            admin: tx_context::sender(ctx),
            emergency_mode: false,
            physical_delivery_enabled: true,
            risk_params: RiskParameters {
                max_position_size: 1000000, // 1M gas credits
                max_total_exposure: 10000000, // 10M gas credits
                liquidation_threshold: 8000, // 80%
                circuit_breaker_threshold: 5000, // 50% price movement
                min_collateral_ratio: 1500, // 150%
            },
            total_redeemed: 0,
            active_contracts: 0,
            expired_contracts: 0,
        };

        // Initialize Enhanced Sui Gas Oracle with External Feeds
        let oracle = SuiGasOracle {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            
            // Primary gas price data
            current_gas_price: 1000, // Initial price in MIST
            confidence: 10000, // 100% initial confidence
            last_update: 0,
            congestion_level: CONGESTION_LOW,
            
            // External oracle integration
            external_oracles: table::new(ctx),
            oracle_source_names: vector::empty(),
            pyth_price_feed_id: option::none(), // To be configured by admin
            chainlink_feed_address: option::none(), // To be configured by admin
            
            // Multi-source price aggregation
            price_sources: vector::empty(),
            aggregated_price: 1000, // Initial aggregated price
            price_weights: table::new(ctx),
            
            // Enhanced data storage
            price_history: vector::empty(),
            max_history_size: 1000, // Store last 1000 price points
            twap_1h: 1000, // Initial TWAP values
            twap_24h: 1000,
            volatility_24h: 0, // Initial volatility
            
            // Circuit breaker and validation
            circuit_breaker_active: false,
            max_price_deviation: 2000, // 20% maximum deviation between sources
            staleness_threshold: 300000, // 5 minutes maximum staleness
            min_confidence_threshold: 7500, // 75% minimum confidence
            
            // Automated update system
            auto_update_enabled: true,
            update_frequency: 60000, // 1 minute minimum between updates
            validator_reporters: vector::empty(),
            
            // Emergency fallback
            backup_price: option::some(1000), // Emergency fallback price
            emergency_price_source: option::none(),
            circuit_breaker_threshold: 5000, // 50% price movement triggers circuit breaker
        };

        let oracle_id = object::uid_to_inner(&oracle.id);
        // Oracle ID is now stored within oracle structure

        transfer::share_object(registry);
        transfer::share_object(oracle);
    }

    // Update Sui gas oracle (should be called by validators or automated system)
    public entry fun update_gas_oracle(
        oracle: &mut SuiGasOracle,
        new_price: u64,
        congestion_level: u8,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time >= oracle.last_update + 300000, E_UNAUTHORIZED); // 5 minutes
        
        let old_price = oracle.current_gas_price;
        oracle.current_gas_price = new_price;
        oracle.congestion_level = congestion_level;
        oracle.last_update = current_time;

        event::emit(OracleUpdated {
            old_price,
            new_price,
            price_change_percentage: 0, // Placeholder for price change percentage
            congestion_level,
            confidence: 10000, // Placeholder for confidence
            timestamp: current_time,
        });
    }

    // Calculate dynamic premium based on congestion
    fun calculate_dynamic_premium(
        base_price: u64, 
        duration_days: u64, 
        congestion_level: u8
    ): u64 {
        let base_premium = if (duration_days == DURATION_30_DAYS) {
            PREMIUM_30_DAYS
        } else if (duration_days == DURATION_60_DAYS) {
            PREMIUM_60_DAYS
        } else if (duration_days == DURATION_90_DAYS) {
            PREMIUM_90_DAYS
        } else {
            abort E_INVALID_DURATION
        };

        // Apply congestion multiplier
        let congestion_multiplier = if (congestion_level == CONGESTION_HIGH) {
            15000 // 150% premium for high congestion
        } else if (congestion_level == CONGESTION_MEDIUM) {
            10000 // 100% premium for medium congestion
        } else {
            5000  // 50% premium for low congestion
        };
        
        let total_premium = base_premium + congestion_multiplier;
        base_price + (base_price * total_premium / 10000)
    }

    // Calculate premium based on duration (legacy function)
    fun calculate_premium(base_price: u64, duration_days: u64): u64 {
        calculate_dynamic_premium(base_price, duration_days, CONGESTION_LOW)
    }

    // Purchase gas futures contract with real token minting
    public entry fun purchase_gas_futures_with_token(
        registry: &mut GasFuturesRegistry,
        gas_registry: &mut GasCreditsRegistry, // For minting tokens
        oracle: &SuiGasOracle,
        payment: Coin<SUI>,
        gas_credits: u64,
        duration_days: u64,
        actual_delivery: bool,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!registry.emergency_mode, E_EMERGENCY_MODE);
        assert!(gas_credits > 0, E_INVALID_AMOUNT);
        assert!(duration_days >= 7 && duration_days <= 365, E_INVALID_DURATION);

        let current_time = clock::timestamp_ms(clock);
        let sender = tx_context::sender(ctx);
        let expiry_timestamp = current_time + (duration_days * 24 * 60 * 60 * 1000);

        // Calculate total price using oracle
        let base_price = gas_credits * oracle.current_gas_price;
        let premium = calculate_premium(base_price, duration_days);
        let total_price = base_price + premium;

        assert!(coin::value(&payment) >= total_price, E_INSUFFICIENT_PAYMENT);

        // MINT ACTUAL GAS_CREDITS TOKENS
        let gas_credits_coin = amm::u64_to_gas_credits_coin(
            gas_registry,
            gas_credits,
            ctx
        );

        // Create contract with real token
        let contract = GasFuturesContract {
            id: object::new(ctx),
            owner: sender,
            gas_credits_amount: gas_credits,
            gas_credits_coin: option::some(gas_credits_coin), // Store real token
            purchase_price: total_price,
            expiry_timestamp,
            duration_days,
            status: 0, // active
            created_at: current_time,
            congestion_at_purchase: oracle.congestion_level,
            actual_delivery,
            voucher_id: option::none(),
        };

        let contract_id = object::uid_to_inner(&contract.id);

        // Update registry
        registry.total_contracts = registry.total_contracts + 1;
        registry.total_volume = registry.total_volume + total_price;
        registry.total_gas_reserved = registry.total_gas_reserved + gas_credits;

        // Store contract in user's list
        if (!table::contains(&registry.contracts, sender)) {
            table::add(&mut registry.contracts, sender, vector::empty<ID>());
        };
        let user_contracts = table::borrow_mut(&mut registry.contracts, sender);
        vector::push_back(user_contracts, contract_id);

        // Add payment to reserve pool
        balance::join(&mut registry.gas_reserve_pool, coin::into_balance(payment));

        event::emit(ContractPurchased {
            contract_id,
            owner: sender,
            gas_credits,
            purchase_price: total_price,
            expiry_timestamp,
            duration_days,
            physical_delivery: actual_delivery,
            congestion_level: oracle.congestion_level,
        });

        transfer::transfer(contract, sender);
    }

    // Redeem gas futures contract with real token transfer
    public entry fun redeem_gas_credits_with_token(
        registry: &mut GasFuturesRegistry,
        gas_registry: &mut GasCreditsRegistry, // For burning tokens if needed
        mut contract: GasFuturesContract,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let sender = tx_context::sender(ctx);
        
        assert!(contract.owner == sender, E_UNAUTHORIZED);
        assert!(contract.status == 0, E_CONTRACT_EXPIRED); // Must be active
        
        // CRITICAL FIX: Contract can be redeemed BEFORE expiry, not after!
        assert!(current_time <= contract.expiry_timestamp, E_CONTRACT_EXPIRED);

        let contract_id = object::uid_to_inner(&contract.id);
        contract.status = 1; // Mark as redeemed

        // Calculate early redemption penalty if applicable
        let time_to_expiry = contract.expiry_timestamp - current_time;
        let full_duration = contract.duration_days * 24 * 60 * 60 * 1000; // Convert to milliseconds
        let early_redemption_penalty = if (time_to_expiry > (full_duration / 10)) { // More than 10% time left
            (contract.gas_credits_amount * 500) / 10000 // 5% penalty
        } else {
            0 // No penalty near expiry
        };

        let final_gas_credits = contract.gas_credits_amount - early_redemption_penalty;

        if (contract.actual_delivery) {
            // Physical delivery - transfer actual gas credits tokens
            if (option::is_some(&contract.gas_credits_coin)) {
                let mut gas_credits_token = option::extract(&mut contract.gas_credits_coin);
                
                // Handle early redemption penalty by burning excess tokens
                if (early_redemption_penalty > 0) {
                    let penalty_amount = coin::value(&gas_credits_token);
                    if (penalty_amount > final_gas_credits) {
                        let penalty_coins = coin::split(&mut gas_credits_token, early_redemption_penalty, ctx);
                        amm::burn_gas_credits(gas_registry, penalty_coins, ctx);
                    };
                };
                
                transfer::public_transfer(gas_credits_token, sender);
                
                // Create voucher for convenience
                let voucher = GasVoucher {
                    id: object::new(ctx),
                    owner: sender,
                    credits: final_gas_credits,
                    original_credits: contract.gas_credits_amount,
                    expiry: contract.expiry_timestamp + 31536000000, // +1 year
                    created_at: current_time,
                    redeemed_amount: 0, // Initially no redemption
                    active: true, // Active voucher
                };

                let voucher_id = object::uid_to_inner(&voucher.id);
                contract.voucher_id = option::some(voucher_id);

                // Store voucher in registry
                if (!table::contains(&registry.vouchers, sender)) {
                    table::add(&mut registry.vouchers, sender, vector::empty<ID>());
                };
                let user_vouchers = table::borrow_mut(&mut registry.vouchers, sender);
                vector::push_back(user_vouchers, voucher_id);

                event::emit(GasVoucherCreated {
                    voucher_id,
                    owner: sender,
                    credits: final_gas_credits,
                    expiry: voucher.expiry,
                    contract_id,
                });

                transfer::transfer(voucher, sender);
                
            } else {
                // Fallback: mint new tokens if none stored
                let gas_credits_token = amm::mint_gas_credits(
                    gas_registry,
                    final_gas_credits,
                    ctx
                );
                transfer::public_transfer(gas_credits_token, sender);
            };

        } else {
            // Cash settlement - return SUI equivalent minus penalty
            let redemption_amount = final_gas_credits * 1000;
            assert!(balance::value(&registry.gas_reserve_pool) >= redemption_amount, E_INSUFFICIENT_RESERVES);
            
            let redemption_coin = coin::take(&mut registry.gas_reserve_pool, redemption_amount, ctx);
            transfer::public_transfer(redemption_coin, sender);

            // Burn the stored gas credits tokens since we're doing cash settlement
            if (option::is_some(&contract.gas_credits_coin)) {
                let gas_credits_to_burn = option::extract(&mut contract.gas_credits_coin);
                amm::burn_gas_credits(gas_registry, gas_credits_to_burn, ctx);
            };
        };

        // Update registry statistics
        registry.total_redeemed = registry.total_redeemed + final_gas_credits;
        registry.active_contracts = registry.active_contracts - 1;

        let voucher_id_opt = if (contract.actual_delivery) contract.voucher_id else option::none();
        let final_redemption_amount = if (contract.actual_delivery) 0 else final_gas_credits * 1000;

        event::emit(ContractRedeemed {
            contract_id,
            owner: contract.owner,
            gas_credits: final_gas_credits,
            redemption_amount: final_redemption_amount,
            physical_delivery: contract.actual_delivery,
            voucher_created: voucher_id_opt,
        });

        transfer::transfer(contract, sender);
    }

    // Use gas voucher for actual transaction fee payment
    public entry fun use_gas_voucher(
        registry: &mut GasFuturesRegistry,
        voucher: &mut GasVoucher,
        gas_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        
        assert!(voucher.owner == tx_context::sender(ctx), E_UNAUTHORIZED);
        assert!(voucher.active, E_ALREADY_REDEEMED);
        assert!(current_time <= voucher.expiry, E_VOUCHER_EXPIRED);
        assert!(voucher.credits >= gas_amount, E_INSUFFICIENT_GAS_CREDITS);
        assert!(gas_amount > 0, E_INVALID_GAS_AMOUNT);

        // Deduct gas amount from voucher
        voucher.credits = voucher.credits - gas_amount;
        voucher.redeemed_amount = voucher.redeemed_amount + gas_amount;

        if (voucher.credits == 0) {
            voucher.active = false;
        };

        let transaction_cost_saved = gas_amount * 1000; // Convert to MIST

        // Create SUI coin from gas reserve pool and transfer to user
        let gas_payment = coin::take(&mut registry.gas_reserve_pool, transaction_cost_saved, ctx);
        transfer::public_transfer(gas_payment, tx_context::sender(ctx));

        event::emit(GasVoucherUsed {
            voucher_id: object::uid_to_inner(&voucher.id),
            owner: voucher.owner,
            gas_amount,
            remaining_credits: voucher.credits,
            transaction_cost_saved,
        });
    }

    // Emergency functions
    public entry fun toggle_emergency_mode(
        registry: &mut GasFuturesRegistry,
        ctx: &mut TxContext
    ) {
        assert!(registry.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        registry.emergency_mode = !registry.emergency_mode;
    }

    public entry fun toggle_physical_delivery(
        registry: &mut GasFuturesRegistry,
        ctx: &mut TxContext
    ) {
        assert!(registry.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        registry.physical_delivery_enabled = !registry.physical_delivery_enabled;
    }

    // NEW: Update risk parameters
    public entry fun update_risk_parameters(
        registry: &mut GasFuturesRegistry,
        max_position_size: u64,
        max_total_exposure: u64,
        liquidation_threshold: u64,
        circuit_breaker_threshold: u64,
        min_collateral_ratio: u64,
        ctx: &mut TxContext
    ) {
        assert!(registry.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        let new_risk_params = RiskParameters {
            max_position_size,
            max_total_exposure,
            liquidation_threshold,
            circuit_breaker_threshold,
            min_collateral_ratio,
        };
        registry.risk_params = new_risk_params;
    }

    // NEW: Reset circuit breaker
    public entry fun reset_circuit_breaker(
        oracle: &mut SuiGasOracle,
        ctx: &mut TxContext
    ) {
        assert!(oracle.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        oracle.circuit_breaker_active = false;
    }

    // Enhanced view functions
    public fun get_contract_info(contract: &GasFuturesContract): (address, u64, u64, u64, u64, u8, u64, bool, Option<ID>) {
        (
            contract.owner,
            contract.gas_credits_amount,
            contract.purchase_price,
            contract.expiry_timestamp,
            contract.duration_days,
            contract.status,
            contract.created_at,
            contract.actual_delivery,
            contract.voucher_id
        )
    }

    public fun get_voucher_info(voucher: &GasVoucher): (address, u64, u64, u64, u64, bool) {
        (
            voucher.owner,
            voucher.credits,
            voucher.original_credits,
            voucher.expiry,
            voucher.redeemed_amount,
            voucher.active
        )
    }

    public fun get_oracle_info(oracle: &SuiGasOracle): (u64, u8, u64, u64, bool) {
        (
            oracle.current_gas_price, 
            oracle.congestion_level, 
            oracle.last_update,
            oracle.confidence,
            oracle.circuit_breaker_active
        )
    }

    public fun get_registry_stats(registry: &GasFuturesRegistry): (u64, u64, u64, bool, bool) {
        (
            registry.total_contracts, 
            registry.total_volume, 
            registry.total_gas_reserved,
            registry.emergency_mode,
            registry.physical_delivery_enabled
        )
    }

    // NEW: Get risk parameters
    public fun get_risk_parameters(registry: &GasFuturesRegistry): (u64, u64, u64, u64, u64) {
        (
            registry.risk_params.max_position_size,
            registry.risk_params.max_total_exposure,
            registry.risk_params.liquidation_threshold,
            registry.risk_params.circuit_breaker_threshold,
            registry.risk_params.min_collateral_ratio
        )
    }

    // NEW: Get price history
    public fun get_price_history(oracle: &SuiGasOracle): &vector<EnhancedPricePoint> {
        &oracle.price_history
    }

    // NEW: Calculate current premium
    public fun calculate_current_premium(
        oracle: &SuiGasOracle,
        gas_credits: u64,
        duration_days: u64
    ): u64 {
        let base_price = gas_credits * oracle.current_gas_price;
        calculate_dynamic_premium(base_price, duration_days, oracle.congestion_level)
    }

    // ======================
    // EXTERNAL ORACLE INTEGRATION FUNCTIONS
    // ======================

    // Configure external oracle sources
    public entry fun configure_external_oracle(
        oracle: &mut SuiGasOracle,
        source_name: vector<u8>,
        oracle_address: Option<address>,
        feed_id: Option<vector<u8>>,
        weight: u64,
        deviation_limit: u64,
        ctx: &mut TxContext
    ) {
        assert!(oracle.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        assert!(weight > 0 && weight <= 10000, E_INVALID_AMOUNT); // Max 100% weight
        assert!(deviation_limit > 0 && deviation_limit <= 5000, E_INVALID_AMOUNT); // Max 50% deviation

        let external_source = ExternalOracleSource {
            source_name,
            oracle_address,
            feed_id,
            last_price: oracle.current_gas_price, // Initialize with current price
            last_update: 0,
            confidence: 10000, // Initial confidence
            is_active: true,
            weight,
            deviation_limit,
        };

        table::add(&mut oracle.external_oracles, source_name, external_source);
        table::add(&mut oracle.price_weights, source_name, weight);

        // Add source name to list for iteration
        vector::push_back(&mut oracle.oracle_source_names, source_name);
    }

    // Update external oracle price (called by authorized reporters or automated system)
    public entry fun update_external_oracle_price(
        oracle: &mut SuiGasOracle,
        source_name: vector<u8>,
        new_price: u64,
        confidence: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let current_time = clock::timestamp_ms(clock);
        
        // Verify authorization (admin or validator reporter)
        let is_authorized = oracle.admin == sender || 
                           vector::contains(&oracle.validator_reporters, &sender);
        assert!(is_authorized, E_UNAUTHORIZED);

        // Verify oracle source exists and is active
        assert!(table::contains(&oracle.external_oracles, source_name), E_ORACLE_NOT_FOUND);
        let external_source = table::borrow_mut(&mut oracle.external_oracles, source_name);
        assert!(external_source.is_active, E_ORACLE_INACTIVE);

        // Validate price and confidence
        assert!(new_price > 0, E_INVALID_PRICE);
        assert!(confidence >= oracle.min_confidence_threshold, E_INSUFFICIENT_CONFIDENCE);

        // Check for price deviation from current aggregated price
        let deviation = calculate_price_deviation(oracle.aggregated_price, new_price);
        assert!(deviation <= external_source.deviation_limit, E_PRICE_DEVIATION_TOO_HIGH);

        // Update external source
        external_source.last_price = new_price;
        external_source.last_update = current_time;
        external_source.confidence = confidence;

        // Add to price sources for aggregation
        let price_data = PriceSourceData {
            source_name,
            price: new_price,
            confidence,
            timestamp: current_time,
            validation_status: 1, // Valid
        };
        vector::push_back(&mut oracle.price_sources, price_data);

        // Trigger price aggregation
        aggregate_price_sources(oracle, current_time);
    }

    // Aggregate prices from all sources using weighted average
    fun aggregate_price_sources(oracle: &mut SuiGasOracle, current_time: u64) {
        let mut total_weighted_price = 0;
        let mut total_weight = 0;
        let mut valid_sources = 0;

        // Clear old price sources (keep only recent ones)
        oracle.price_sources = vector::empty();

        // Iterate through external oracles
        let source_names = oracle.oracle_source_names;
        let mut i = 0;
        let source_count = vector::length(&source_names);

        while (i < source_count) {
            let source_name = *vector::borrow(&source_names, i);
            let external_source = table::borrow(&oracle.external_oracles, source_name);

            // Check if source is active and not stale
            let is_fresh = current_time - external_source.last_update <= oracle.staleness_threshold;
            let is_confident = external_source.confidence >= oracle.min_confidence_threshold;

            if (external_source.is_active && is_fresh && is_confident) {
                let weight = *table::borrow(&oracle.price_weights, source_name);
                total_weighted_price = total_weighted_price + (external_source.last_price * weight);
                total_weight = total_weight + weight;
                valid_sources = valid_sources + 1;

                // Add to current price sources
                let price_data = PriceSourceData {
                    source_name,
                    price: external_source.last_price,
                    confidence: external_source.confidence,
                    timestamp: external_source.last_update,
                    validation_status: 1, // Valid
                };
                vector::push_back(&mut oracle.price_sources, price_data);
            };

            i = i + 1;
        };

        // Include internal SUI network price with high weight
        if (current_time - oracle.last_update <= oracle.staleness_threshold) {
            let internal_weight = 3000; // 30% weight for internal oracle
            total_weighted_price = total_weighted_price + (oracle.current_gas_price * internal_weight);
            total_weight = total_weight + internal_weight;
            valid_sources = valid_sources + 1;

            // Add internal source to price sources
            let internal_price_data = PriceSourceData {
                source_name: b"sui_network",
                price: oracle.current_gas_price,
                confidence: oracle.confidence,
                timestamp: oracle.last_update,
                validation_status: 1, // Valid
            };
            vector::push_back(&mut oracle.price_sources, internal_price_data);
        };

        // Calculate aggregated price
        if (total_weight > 0 && valid_sources >= 2) { // Require at least 2 sources
            oracle.aggregated_price = total_weighted_price / total_weight;
            
            // Update TWAP values
            update_twap_values(oracle, current_time);
            
            // Update volatility
            update_volatility(oracle);
            
            // Check for circuit breaker conditions
            check_circuit_breaker(oracle, current_time);
            
            // Update price history
            add_to_price_history(oracle, current_time, valid_sources);
        } else {
            // Use fallback price if insufficient valid sources
            if (option::is_some(&oracle.backup_price)) {
                oracle.aggregated_price = *option::borrow(&oracle.backup_price);
            };
        };
    }

    // Calculate price deviation percentage
    fun calculate_price_deviation(price1: u64, price2: u64): u64 {
        let diff = if (price1 > price2) { price1 - price2 } else { price2 - price1 };
        (diff * 10000) / price1 // Return in basis points
    }

    // Update TWAP (Time-Weighted Average Price) values
    fun update_twap_values(oracle: &mut SuiGasOracle, current_time: u64) {
        let history_len = vector::length(&oracle.price_history);
        
        if (history_len > 0) {
            // Calculate 1-hour TWAP
            let mut total_price_1h = 0;
            let mut count_1h = 0;
            let one_hour_ago = if (current_time > 3600000) { current_time - 3600000 } else { 0 };
            
            // Calculate 24-hour TWAP
            let mut total_price_24h = 0;
            let mut count_24h = 0;
            let one_day_ago = if (current_time > 86400000) { current_time - 86400000 } else { 0 };
            
            let mut i = 0;
            while (i < history_len) {
                let price_point = vector::borrow(&oracle.price_history, i);
                
                if (price_point.timestamp >= one_hour_ago) {
                    total_price_1h = total_price_1h + price_point.aggregated_price;
                    count_1h = count_1h + 1;
                };
                
                if (price_point.timestamp >= one_day_ago) {
                    total_price_24h = total_price_24h + price_point.aggregated_price;
                    count_24h = count_24h + 1;
                };
                
                i = i + 1;
            };
            
            if (count_1h > 0) {
                oracle.twap_1h = total_price_1h / count_1h;
            };
            
            if (count_24h > 0) {
                oracle.twap_24h = total_price_24h / count_24h;
            };
        };
    }

    // Update 24-hour volatility measure
    fun update_volatility(oracle: &mut SuiGasOracle) {
        let history_len = vector::length(&oracle.price_history);
        
        if (history_len >= 24) { // Need at least 24 data points
            let mut price_sum = 0;
            let mut variance_sum = 0;
            let count = min_u64(history_len, 144); // Use last 24 hours (assuming 10min intervals)
            
            // Calculate average price
            let mut i = history_len - count;
            while (i < history_len) {
                let price_point = vector::borrow(&oracle.price_history, i);
                price_sum = price_sum + price_point.aggregated_price;
                i = i + 1;
            };
            let avg_price = price_sum / count;
            
            // Calculate variance
            i = history_len - count;
            while (i < history_len) {
                let price_point = vector::borrow(&oracle.price_history, i);
                let diff = if (price_point.aggregated_price > avg_price) {
                    price_point.aggregated_price - avg_price
                } else {
                    avg_price - price_point.aggregated_price
                };
                variance_sum = variance_sum + (diff * diff);
                i = i + 1;
            };
            
            // Volatility as standard deviation percentage
            let variance = variance_sum / count;
            let std_dev = sqrt_u64(variance);
            oracle.volatility_24h = (std_dev * 10000) / avg_price; // In basis points
        };
    }

    // Check circuit breaker conditions
    fun check_circuit_breaker(oracle: &mut SuiGasOracle, current_time: u64) {
        let history_len = vector::length(&oracle.price_history);
        
        if (history_len > 0) {
            let latest_point = vector::borrow(&oracle.price_history, history_len - 1);
            let price_change = calculate_price_deviation(latest_point.aggregated_price, oracle.aggregated_price);
            
            if (price_change >= oracle.circuit_breaker_threshold) {
                oracle.circuit_breaker_active = true;
                
                // Emit circuit breaker event
                event::emit(CircuitBreakerActivated {
                    timestamp: current_time,
                    trigger_reason: b"Price deviation exceeded threshold",
                    current_risk_level: price_change,
                });
            };
        };
    }

    // Add new price point to history
    fun add_to_price_history(oracle: &mut SuiGasOracle, current_time: u64, source_count: u64) {
        let new_point = EnhancedPricePoint {
            timestamp: current_time,
            price: oracle.current_gas_price,
            aggregated_price: oracle.aggregated_price,
            congestion: oracle.congestion_level,
            confidence: oracle.confidence,
            source_count,
            volatility: oracle.volatility_24h,
            volume: option::none(), // Volume data not available yet
        };
        
        vector::push_back(&mut oracle.price_history, new_point);
        
        // Remove old points if exceeding max size
        while (vector::length(&oracle.price_history) > oracle.max_history_size) {
            vector::remove(&mut oracle.price_history, 0);
        };
    }

    // Helper function for minimum value
    fun min_u64(a: u64, b: u64): u64 {
        if (a < b) a else b
    }

    // Square root function (simplified)
    fun sqrt_u64(x: u64): u64 {
        if (x == 0) return 0;
        if (x == 1) return 1;
        
        let mut z = (x + 1) / 2;
        let mut y = x;
        
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        };
        
        y
    }

    // ======================
    // ENHANCED ORACLE MANAGEMENT FUNCTIONS
    // ======================

    // Configure Pyth Network integration
    public entry fun configure_pyth_oracle(
        oracle: &mut SuiGasOracle,
        feed_id: vector<u8>,
        ctx: &mut TxContext
    ) {
        assert!(oracle.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        oracle.pyth_price_feed_id = option::some(feed_id);
        
        // Configure Pyth as external source
        configure_external_oracle(
            oracle,
            b"pyth_network",
            option::none(), // No specific address for Pyth
            option::some(feed_id),
            2500, // 25% weight
            1500, // 15% max deviation
            ctx
        );
    }

    // Configure Chainlink integration
    public entry fun configure_chainlink_oracle(
        oracle: &mut SuiGasOracle,
        chainlink_address: address,
        ctx: &mut TxContext
    ) {
        assert!(oracle.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        oracle.chainlink_feed_address = option::some(chainlink_address);
        
        // Configure Chainlink as external source
        configure_external_oracle(
            oracle,
            b"chainlink",
            option::some(chainlink_address),
            option::none(),
            2000, // 20% weight
            1200, // 12% max deviation
            ctx
        );
    }

    // Add authorized validator reporter
    public entry fun add_validator_reporter(
        oracle: &mut SuiGasOracle,
        validator: address,
        ctx: &mut TxContext
    ) {
        assert!(oracle.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        if (!vector::contains(&oracle.validator_reporters, &validator)) {
            vector::push_back(&mut oracle.validator_reporters, validator);
        };
    }

    // Remove validator reporter
    public entry fun remove_validator_reporter(
        oracle: &mut SuiGasOracle,
        validator: address,
        ctx: &mut TxContext
    ) {
        assert!(oracle.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        let (found, index) = vector::index_of(&oracle.validator_reporters, &validator);
        if (found) {
            vector::remove(&mut oracle.validator_reporters, index);
        };
    }

    // Update oracle configuration parameters
    public entry fun update_oracle_config(
        oracle: &mut SuiGasOracle,
        max_deviation: u64,
        staleness_threshold: u64,
        min_confidence: u64,
        circuit_breaker_threshold: u64,
        ctx: &mut TxContext
    ) {
        assert!(oracle.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        assert!(max_deviation <= 5000, E_INVALID_AMOUNT); // Max 50%
        assert!(min_confidence >= 5000, E_INVALID_AMOUNT); // Min 50%
        assert!(circuit_breaker_threshold >= 1000, E_INVALID_AMOUNT); // Min 10%
        
        oracle.max_price_deviation = max_deviation;
        oracle.staleness_threshold = staleness_threshold;
        oracle.min_confidence_threshold = min_confidence;
        oracle.circuit_breaker_threshold = circuit_breaker_threshold;
    }

    // Manual emergency price update (only admin)
    public entry fun emergency_price_update(
        oracle: &mut SuiGasOracle,
        emergency_price: u64,
        reason: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(oracle.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        assert!(emergency_price > 0, E_INVALID_PRICE);
        
        let current_time = clock::timestamp_ms(clock);
        
        // Set emergency price as backup
        oracle.backup_price = option::some(emergency_price);
        oracle.aggregated_price = emergency_price;
        oracle.last_update = current_time;
        
        // Activate circuit breaker
        oracle.circuit_breaker_active = true;
        
        // Emit emergency event
        event::emit(CircuitBreakerActivated {
            timestamp: current_time,
            trigger_reason: reason,
            current_risk_level: 10000, // Maximum risk level
        });
    }

    // Get comprehensive oracle status
    public fun get_oracle_status(oracle: &SuiGasOracle): (
        u64,    // current_gas_price
        u64,    // aggregated_price
        u64,    // confidence
        u8,     // congestion_level
        u64,    // last_update
        bool,   // circuit_breaker_active
        u64,    // twap_1h
        u64,    // twap_24h
        u64,    // volatility_24h
        u64     // active_sources_count
    ) {
        let active_sources = count_active_sources(oracle);
        (
            oracle.current_gas_price,
            oracle.aggregated_price,
            oracle.confidence,
            oracle.congestion_level,
            oracle.last_update,
            oracle.circuit_breaker_active,
            oracle.twap_1h,
            oracle.twap_24h,
            oracle.volatility_24h,
            active_sources
        )
    }

    // Count active oracle sources
    fun count_active_sources(oracle: &SuiGasOracle): u64 {
        let mut active_count = 0;
        let mut i = 0;
        let source_count = vector::length(&oracle.oracle_source_names);
        
        while (i < source_count) {
            let source_name = *vector::borrow(&oracle.oracle_source_names, i);
            let external_source = table::borrow(&oracle.external_oracles, source_name);
            if (external_source.is_active) {
                active_count = active_count + 1;
            };
            i = i + 1;
        };
        
        active_count
    }

    // Get external oracle details
    public fun get_external_oracle_info(
        oracle: &SuiGasOracle,
        source_name: vector<u8>
    ): (u64, u64, u64, bool, u64) {
        assert!(table::contains(&oracle.external_oracles, source_name), E_ORACLE_NOT_FOUND);
        let external_source = table::borrow(&oracle.external_oracles, source_name);
        (
            external_source.last_price,
            external_source.last_update,
            external_source.confidence,
            external_source.is_active,
            external_source.weight
        )
    }

    // Get price sources summary
    public fun get_price_sources_summary(oracle: &SuiGasOracle): &vector<PriceSourceData> {
        &oracle.price_sources
    }

    // Automated price update with multi-source validation
    public entry fun automated_price_update(
        oracle: &mut SuiGasOracle,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let sender = tx_context::sender(ctx);
        
        // Check if auto-update is enabled
        assert!(oracle.auto_update_enabled, E_UNAUTHORIZED);
        
        // Check if enough time has passed since last update
        assert!(current_time >= oracle.last_update + oracle.update_frequency, E_STALE_PRICE);
        
        // Verify authorization
        let is_authorized = oracle.admin == sender || 
                           vector::contains(&oracle.validator_reporters, &sender);
        assert!(is_authorized, E_UNAUTHORIZED);
        
        // Trigger aggregation of all current sources
        aggregate_price_sources(oracle, current_time);
        
        // Update internal price to aggregated price
        oracle.current_gas_price = oracle.aggregated_price;
        oracle.last_update = current_time;
        
        // Emit update event
        event::emit(OracleUpdated {
            old_price: oracle.current_gas_price,
            new_price: oracle.aggregated_price,
            price_change_percentage: calculate_price_deviation(oracle.current_gas_price, oracle.aggregated_price),
            congestion_level: oracle.congestion_level,
            confidence: oracle.confidence,
            timestamp: current_time,
        });
    }

    // Health check for oracle system
    public entry fun oracle_health_check(
        oracle: &mut SuiGasOracle,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(oracle.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        let current_time = clock::timestamp_ms(clock);
        let mut unhealthy_sources = vector::empty<vector<u8>>();
        
        // Check each external source
        let mut i = 0;
        let source_count = vector::length(&oracle.oracle_source_names);
        
        while (i < source_count) {
            let source_name = *vector::borrow(&oracle.oracle_source_names, i);
            let external_source = table::borrow(&oracle.external_oracles, source_name);
            
            // Check if source is stale or has low confidence
            let is_stale = current_time - external_source.last_update > oracle.staleness_threshold * 2;
            let is_low_confidence = external_source.confidence < oracle.min_confidence_threshold;
            
            if (is_stale || is_low_confidence) {
                vector::push_back(&mut unhealthy_sources, source_name);
            };
            
            i = i + 1;
        };
        
        // Deactivate unhealthy sources if too many
        if (vector::length(&unhealthy_sources) > source_count / 2) {
            oracle.circuit_breaker_active = true;
        };
    }

    // NEW: Handle expired contracts automatically 
    public entry fun process_expired_contracts(
        registry: &mut GasFuturesRegistry,
        mut expired_contracts: vector<GasFuturesContract>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let admin = tx_context::sender(ctx);
        
        assert!(registry.admin == admin, E_UNAUTHORIZED);
        
        let mut i = 0;
        let contracts_count = vector::length(&expired_contracts);
        
        while (i < contracts_count) {
            let mut contract = vector::pop_back(&mut expired_contracts);
            let contract_id = object::uid_to_inner(&contract.id);
            let contract_owner = contract.owner; // Store owner before transferring
            
            // Verify contract is actually expired
            if (current_time > contract.expiry_timestamp && contract.status == 0) {
                contract.status = 2; // Mark as expired
                
                // For expired contracts, tokens go to protocol treasury
                if (option::is_some(&contract.gas_credits_coin)) {
                    let expired_tokens = option::extract(&mut contract.gas_credits_coin);
                    
                    // Transfer expired tokens to admin treasury
                    transfer::public_transfer(expired_tokens, admin);
                };
                
                registry.active_contracts = registry.active_contracts - 1;
                registry.expired_contracts = registry.expired_contracts + 1;
                
                event::emit(ContractExpired {
                    contract_id,
                    owner: contract.owner,
                    gas_credits: contract.gas_credits_amount,
                });
            };
            
            // Transfer contract back to owner (even if expired, they still own the object)
            transfer::transfer(contract, contract_owner);
            i = i + 1;
        };
        
        vector::destroy_empty(expired_contracts);
    }

    // NEW: Check if contract can be redeemed (time validation)
    public fun can_redeem_contract(
        contract: &GasFuturesContract,
        clock: &Clock
    ): bool {
        let current_time = clock::timestamp_ms(clock);
        current_time <= contract.expiry_timestamp && contract.status == 0
    }

    // NEW: Calculate early redemption penalty
    public fun calculate_early_redemption_penalty(
        contract: &GasFuturesContract,
        clock: &Clock
    ): u64 {
        let current_time = clock::timestamp_ms(clock);
        let time_to_expiry = if (contract.expiry_timestamp > current_time) {
            contract.expiry_timestamp - current_time
        } else {
            0
        };
        
        let full_duration = contract.duration_days * 24 * 60 * 60 * 1000;
        
        if (time_to_expiry > (full_duration / 10)) { // More than 10% time left
            (contract.gas_credits_amount * 500) / 10000 // 5% penalty
        } else {
            0 // No penalty near expiry
        }
    }

    // NEW: Batch contract expiration processing
    public entry fun batch_expire_contracts(
        registry: &mut GasFuturesRegistry,
        contract_ids: vector<ID>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(registry.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        let current_time = clock::timestamp_ms(clock);
        let mut i = 0;
        let count = vector::length(&contract_ids);
        
        while (i < count) {
            let contract_id = *vector::borrow(&contract_ids, i);
            
            // Mark contract as expired in registry
            // Note: This is a simplified approach, actual implementation would need
            // to handle the contract objects individually
            
            event::emit(ContractExpired {
                contract_id,
                owner: @0x0, // Would need to get from actual contract
                gas_credits: 0, // Would need to get from actual contract
            });
            
            i = i + 1;
        };
        
        registry.expired_contracts = registry.expired_contracts + count;
        registry.active_contracts = registry.active_contracts - count;
    }
}