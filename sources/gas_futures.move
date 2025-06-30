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

    // Sui network gas oracle integration
    public struct SuiGasOracle has key {
        id: UID,
        admin: address,
        current_gas_price: u64,
        congestion_level: u8,
        last_update: u64,
        confidence: u64,
        price_history: vector<PricePoint>,
        backup_price: Option<u64>,
        circuit_breaker_active: bool,
    }

    // Gas futures contract structure (enhanced)
    public struct GasFuturesContract has key, store {
        id: UID,
        owner: address,
        gas_credits: u64,
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
        };

        // Initialize Sui Gas Oracle
        let oracle = SuiGasOracle {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            current_gas_price: 1000, // Initial price in MIST
            congestion_level: CONGESTION_LOW,
            last_update: 0,
            confidence: 10000, // 100%
            price_history: vector::empty(),
            backup_price: option::none(),
            circuit_breaker_active: false,
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

    // Enhanced purchase function with physical delivery option
    public entry fun purchase_gas_futures(
        registry: &mut GasFuturesRegistry,
        oracle: &SuiGasOracle,
        payment: Coin<SUI>,
        gas_credits: u64,
        duration_days: u64,
        physical_delivery: bool,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!registry.emergency_mode, E_UNAUTHORIZED);
        
        // Validate duration
        assert!(
            duration_days == DURATION_30_DAYS || 
            duration_days == DURATION_60_DAYS || 
            duration_days == DURATION_90_DAYS,
            E_INVALID_DURATION
        );

        let current_time = clock::timestamp_ms(clock);
        let base_price = gas_credits * oracle.current_gas_price;
        let total_price = calculate_dynamic_premium(base_price, duration_days, oracle.congestion_level);
        
        // Validate payment amount
        assert!(coin::value(&payment) >= total_price, E_INSUFFICIENT_PAYMENT);

        // Calculate expiry timestamp
        let expiry_timestamp = current_time + (duration_days * 24 * 60 * 60 * 1000);

        // Create contract
        let contract = GasFuturesContract {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            gas_credits,
            purchase_price: total_price,
            expiry_timestamp,
            duration_days,
            status: 0, // active
            created_at: current_time,
            congestion_at_purchase: oracle.congestion_level,
            actual_delivery: physical_delivery,
            voucher_id: option::none(),
        };

        let contract_id = object::uid_to_inner(&contract.id);
        registry.total_contracts = registry.total_contracts + 1;
        registry.total_volume = registry.total_volume + total_price;

        if (physical_delivery) {
            registry.total_gas_reserved = registry.total_gas_reserved + gas_credits;
        };

        // Store contract reference
        let sender = tx_context::sender(ctx);
        if (!table::contains(&registry.contracts, sender)) {
            table::add(&mut registry.contracts, sender, vector::empty<ID>());
        };
        let user_contracts = table::borrow_mut(&mut registry.contracts, sender);
        vector::push_back(user_contracts, contract_id);

        // Add payment to gas reserve pool for physical delivery
        if (physical_delivery) {
            balance::join(&mut registry.gas_reserve_pool, coin::into_balance(payment));
        } else {
            // Transfer payment to treasury for cash settled contracts
            transfer::public_transfer(payment, @0x0);
        };

        // Emit event
        event::emit(ContractPurchased {
            contract_id,
            owner: sender,
            gas_credits,
            purchase_price: total_price,
            expiry_timestamp,
            duration_days,
            physical_delivery,
            congestion_level: oracle.congestion_level,
        });
        
        // Transfer contract to user
        transfer::transfer(contract, sender);
    }

    // Enhanced redeem function with physical delivery
    public entry fun redeem_gas_credits(
        registry: &mut GasFuturesRegistry,
        mut contract: GasFuturesContract,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        
        // Check contract ownership
        assert!(contract.owner == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        // Check contract status
        assert!(contract.status == 0, E_ALREADY_REDEEMED);
        
        // Check if contract is not expired
        assert!(current_time <= contract.expiry_timestamp, E_CONTRACT_EXPIRED);

        let sender = tx_context::sender(ctx);
        let contract_id = object::uid_to_inner(&contract.id);
        let voucher_id_opt = if (contract.actual_delivery && registry.physical_delivery_enabled) {
            // Create gas voucher for physical delivery
            let voucher = GasVoucher {
                id: object::new(ctx),
                owner: sender,
                credits: contract.gas_credits,
                original_credits: contract.gas_credits,
                expiry: contract.expiry_timestamp,
                created_at: current_time,
                redeemed_amount: 0,
                active: true,
            };

            let voucher_id = object::uid_to_inner(&voucher.id);
            
            // Store voucher reference
            if (!table::contains(&registry.vouchers, sender)) {
                table::add(&mut registry.vouchers, sender, vector::empty<ID>());
            };
            let user_vouchers = table::borrow_mut(&mut registry.vouchers, sender);
            vector::push_back(user_vouchers, voucher_id);

            contract.voucher_id = option::some(voucher_id);

            event::emit(GasVoucherCreated {
                voucher_id,
                owner: sender,
                credits: contract.gas_credits,
                expiry: contract.expiry_timestamp,
                contract_id,
            });

            transfer::transfer(voucher, sender);
            option::some(voucher_id)
        } else {
            // Cash settlement - return SUI equivalent
            let redemption_amount = contract.gas_credits * 1000;
            let redemption_coin = coin::take(&mut registry.gas_reserve_pool, redemption_amount, ctx);
            transfer::public_transfer(redemption_coin, sender);
            option::none()
        };

        // Update contract status
        contract.status = 1; // redeemed

        // Emit event
        event::emit(ContractRedeemed {
            contract_id,
            owner: contract.owner,
            gas_credits: contract.gas_credits,
            redemption_amount: if (contract.actual_delivery) 0 else contract.gas_credits * 1000,
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
            contract.gas_credits,
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
    public fun get_price_history(oracle: &SuiGasOracle): &vector<PricePoint> {
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
}