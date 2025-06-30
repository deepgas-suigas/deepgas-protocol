/// Oracle System for Gas Futures Platform
/// Provides reliable price feeds using Pyth Network integration
module gas_futures::oracle {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::table::{Self, Table};
    use sui::transfer;
    use std::vector;
    use std::option::{Self, Option};

    // Error codes
    const E_UNAUTHORIZED: u64 = 1;
    const E_STALE_PRICE: u64 = 2;
    const E_INVALID_PRICE: u64 = 3;
    const E_PRICE_DEVIATION_TOO_HIGH: u64 = 4;
    const E_INSUFFICIENT_CONFIDENCE: u64 = 5;
    const E_ORACLE_NOT_FOUND: u64 = 6;
    const E_INVALID_SYMBOL: u64 = 7;
    const E_ORACLE_INACTIVE: u64 = 8;
    const E_EMERGENCY_MODE_ACTIVE: u64 = 9;
    const E_INSUFFICIENT_SOURCES: u64 = 10;

    // Oracle configuration constants
    const MAX_PRICE_AGE: u64 = 300000; // 5 minutes in milliseconds
    const MIN_CONFIDENCE_LEVEL: u64 = 8500; // 85% confidence required
    const MAX_PRICE_DEVIATION: u64 = 1000; // 10% maximum deviation
    const PRECISION: u64 = 1000000; // 1e6 for decimal precision
    const MAX_SYMBOLS: u64 = 100; // Maximum number of symbols supported

    // Price aggregation types
    const AGGREGATION_MEDIAN: u8 = 1;
    const AGGREGATION_WEIGHTED_AVERAGE: u8 = 2;
    const AGGREGATION_TWAP: u8 = 3; // Time-weighted average price

    // Oracle types
    const ORACLE_TYPE_PYTH: u8 = 1;
    const ORACLE_TYPE_CHAINLINK: u8 = 2;
    const ORACLE_TYPE_BINANCE: u8 = 3;
    const ORACLE_TYPE_COINGECKO: u8 = 4;

    // Math utility functions
    fun min_u64(a: u64, b: u64): u64 {
        if (a < b) a else b
    }

    fun max_u64(a: u64, b: u64): u64 {
        if (a > b) a else b
    }

    fun sqrt_u64(x: u64): u64 {
        if (x == 0) return 0;
        if (x == 1) return 1;
        
        // Newton's method for square root
        let mut z = (x + 1) / 2;
        let mut y = x;
        
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        };
        
        y
    }

    // Oracle data source
    public struct PriceOracle has key, store {
        id: UID,
        symbol: vector<u8>,
        price: u64,
        confidence: u64,
        timestamp: u64,
        expo: u8,
        ema_price: u64,
        ema_confidence: u64,
        source: vector<u8>, // "pyth", "chainlink", etc.
        oracle_type: u8,
        is_active: bool,
        min_publishers: u64,
        update_count: u64,
        last_anomaly: Option<u64>,
    }

    // Price feed registry
    public struct OracleRegistry has key {
        id: UID,
        oracles: Table<vector<u8>, ID>, // symbol -> oracle ID
        oracle_addresses: Table<vector<u8>, address>, // symbol -> oracle address
        aggregation_method: u8,
        admin: address,
        emergency_mode: bool,
        total_updates: u64,
        last_health_check: u64,
        supported_symbols: vector<vector<u8>>,
        price_feeds: Table<vector<u8>, PriceFeed>,
        circuit_breaker_active: bool,
        max_deviation_threshold: u64,
    }

    // Price feed for efficient lookups
    public struct PriceFeed has store, drop {
        symbol: vector<u8>,
        oracle_id: ID,
        last_price: u64,
        last_update: u64,
        update_frequency: u64,
        is_critical: bool, // For gas price feeds
    }

    // Price update data
    public struct PriceUpdate has key, store {
        id: UID,
        oracle_symbol: vector<u8>,
        old_price: u64,
        new_price: u64,
        confidence: u64,
        timestamp: u64,
        updater: address,
        deviation_percentage: u64,
        source_type: u8,
    }

    // Aggregated price data for complex calculations
    public struct AggregatedPrice has key, store {
        id: UID,
        symbol: vector<u8>,
        price: u64,
        confidence: u64,
        timestamp: u64,
        source_count: u64,
        twap_1h: u64,
        twap_24h: u64,
        volatility: u64,
        volume_weighted_price: Option<u64>,
        price_sources: vector<PriceSource>,
    }

    // Individual price source in aggregation
    public struct PriceSource has store, drop {
        source: vector<u8>,
        price: u64,
        confidence: u64,
        timestamp: u64,
        weight: u64,
    }

    // Historical price point for TWAP calculations
    public struct PricePoint has store, drop {
        price: u64,
        timestamp: u64,
        volume: Option<u64>,
        confidence: u64,
    }

    // Price history storage
    public struct PriceHistory has key, store {
        id: UID,
        symbol: vector<u8>,
        prices: vector<PricePoint>,
        max_size: u64,
        total_points: u64,
    }

    // Events
    public struct PriceUpdated has copy, drop {
        symbol: vector<u8>,
        price: u64,
        confidence: u64,
        timestamp: u64,
        source: vector<u8>,
        deviation: u64,
        update_count: u64,
    }

    public struct PriceAggregated has copy, drop {
        symbol: vector<u8>,
        aggregated_price: u64,
        confidence: u64,
        source_count: u64,
        method: u8,
        timestamp: u64,
        twap_1h: u64,
        twap_24h: u64,
    }

    public struct OracleCreated has copy, drop {
        symbol: vector<u8>,
        oracle_id: ID,
        oracle_address: address,
        source: vector<u8>,
        oracle_type: u8,
        creator: address,
    }

    public struct EmergencyModeActivated has copy, drop {
        reason: vector<u8>,
        timestamp: u64,
        admin: address,
        affected_symbols: vector<vector<u8>>,
    }

    public struct PriceAnomaly has copy, drop {
        symbol: vector<u8>,
        current_price: u64,
        previous_price: u64,
        deviation_percentage: u64,
        timestamp: u64,
        confidence: u64,
        action_taken: vector<u8>,
    }

    public struct CircuitBreakerTriggered has copy, drop {
        symbol: vector<u8>,
        trigger_price: u64,
        threshold_exceeded: u64,
        timestamp: u64,
        auto_disabled: bool,
    }

    // Initialize oracle system
    fun init(ctx: &mut TxContext) {
        let registry = OracleRegistry {
            id: object::new(ctx),
            oracles: table::new(ctx),
            oracle_addresses: table::new(ctx),
            aggregation_method: AGGREGATION_WEIGHTED_AVERAGE,
            admin: tx_context::sender(ctx),
            emergency_mode: false,
            total_updates: 0,
            last_health_check: 0,
            supported_symbols: vector::empty(),
            price_feeds: table::new(ctx),
            circuit_breaker_active: false,
            max_deviation_threshold: 2000, // 20% for circuit breaker
        };
        transfer::share_object(registry);
    }

    // Create new price oracle
    public entry fun create_oracle(
        registry: &mut OracleRegistry,
        symbol: vector<u8>,
        source: vector<u8>,
        oracle_type: u8,
        initial_price: u64,
        expo: u8,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(registry.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        assert!(!table::contains(&registry.oracles, symbol), E_ORACLE_NOT_FOUND);
        assert!(vector::length(&registry.supported_symbols) < MAX_SYMBOLS, E_INVALID_SYMBOL);
        
        let current_time = clock::timestamp_ms(clock);
        
        let oracle = PriceOracle {
            id: object::new(ctx),
            symbol: symbol,
            price: initial_price,
            confidence: 10000, // 100% initial confidence
            timestamp: current_time,
            expo,
            ema_price: initial_price,
            ema_confidence: 10000,
            source: source,
            oracle_type,
            is_active: true,
            min_publishers: 1,
            update_count: 0,
            last_anomaly: option::none(),
        };

        let oracle_id = object::uid_to_inner(&oracle.id);
        let oracle_address = object::uid_to_address(&oracle.id);
        
        // Add to registry
        table::add(&mut registry.oracles, symbol, oracle_id);
        table::add(&mut registry.oracle_addresses, symbol, oracle_address);
        
        // Add to supported symbols
        vector::push_back(&mut registry.supported_symbols, symbol);
        
        // Create price feed entry
        let price_feed = PriceFeed {
            symbol: symbol,
            oracle_id,
            last_price: initial_price,
            last_update: current_time,
            update_frequency: 300000, // 5 minutes default
            is_critical: symbol == b"GAS" || symbol == b"SUI", // Mark gas-related feeds as critical
        };
        table::add(&mut registry.price_feeds, symbol, price_feed);
        
        // Create price history
        let mut price_history = PriceHistory {
            id: object::new(ctx),
            symbol: symbol,
            prices: vector::empty(),
            max_size: 1000, // Keep last 1000 price points
            total_points: 0,
        };
        
        // Add initial price point
        let initial_point = PricePoint {
            price: initial_price,
            timestamp: current_time,
            volume: option::none(),
            confidence: 10000,
        };
        vector::push_back(&mut price_history.prices, initial_point);
        price_history.total_points = 1;

        event::emit(OracleCreated {
            symbol: symbol,
            oracle_id,
            oracle_address,
            source: source,
            oracle_type,
            creator: tx_context::sender(ctx),
        });

        transfer::share_object(oracle);
        transfer::share_object(price_history);
    }

    // Enhanced price update with comprehensive validation
    public entry fun update_price(
        registry: &mut OracleRegistry,
        oracle: &mut PriceOracle,
        new_price: u64,
        confidence: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        
        // Validate basic requirements
        assert!(oracle.is_active, E_ORACLE_INACTIVE);
        assert!(confidence >= MIN_CONFIDENCE_LEVEL, E_INSUFFICIENT_CONFIDENCE);
        assert!(new_price > 0, E_INVALID_PRICE);
        assert!(!registry.emergency_mode || registry.admin == tx_context::sender(ctx), E_EMERGENCY_MODE_ACTIVE);
        
        // Check for price anomalies
        let price_deviation = calculate_price_deviation(oracle.price, new_price);
        let is_anomaly = price_deviation > MAX_PRICE_DEVIATION;
        
        if (is_anomaly) {
            oracle.last_anomaly = option::some(current_time);
            
            event::emit(PriceAnomaly {
                symbol: oracle.symbol,
                current_price: new_price,
                previous_price: oracle.price,
                deviation_percentage: price_deviation,
                timestamp: current_time,
                confidence,
                action_taken: if (registry.circuit_breaker_active) b"REJECTED" else b"ACCEPTED",
            });
            
            // Circuit breaker logic
            if (price_deviation > registry.max_deviation_threshold) {
                registry.circuit_breaker_active = true;
                
                event::emit(CircuitBreakerTriggered {
                    symbol: oracle.symbol,
                    trigger_price: new_price,
                    threshold_exceeded: price_deviation,
                    timestamp: current_time,
                    auto_disabled: false,
                });
                
                // In circuit breaker mode, reject extreme changes
                if (registry.admin != tx_context::sender(ctx)) {
                    assert!(false, E_PRICE_DEVIATION_TOO_HIGH);
                }
            }
        };

        let old_price = oracle.price;

        // Update EMA (Exponential Moving Average) with dynamic alpha
        let alpha = if (is_anomaly) 1000 else 2000; // 10% or 20% weight
        oracle.ema_price = (oracle.ema_price * (10000 - alpha) + new_price * alpha) / 10000;
        oracle.ema_confidence = (oracle.ema_confidence * (10000 - alpha) + confidence * alpha) / 10000;

        // Update oracle data
        oracle.price = new_price;
        oracle.confidence = confidence;
        oracle.timestamp = current_time;
        oracle.update_count = oracle.update_count + 1;

        // Update registry statistics
        registry.total_updates = registry.total_updates + 1;
        
        // Update price feed cache
        if (table::contains(&registry.price_feeds, oracle.symbol)) {
            let price_feed = table::borrow_mut(&mut registry.price_feeds, oracle.symbol);
            price_feed.last_price = new_price;
            price_feed.last_update = current_time;
        };

        // Create price update record
        let price_update = PriceUpdate {
            id: object::new(ctx),
            oracle_symbol: oracle.symbol,
            old_price,
            new_price,
            confidence,
            timestamp: current_time,
            updater: tx_context::sender(ctx),
            deviation_percentage: price_deviation,
            source_type: oracle.oracle_type,
        };

        event::emit(PriceUpdated {
            symbol: oracle.symbol,
            price: new_price,
            confidence,
            timestamp: current_time,
            source: oracle.source,
            deviation: price_deviation,
            update_count: oracle.update_count,
        });

        transfer::transfer(price_update, tx_context::sender(ctx));
    }

    // Get current price with staleness check
    public fun get_price(
        oracle: &PriceOracle,
        clock: &Clock
    ): (u64, u64, u64) {
        let current_time = clock::timestamp_ms(clock);
        let age = current_time - oracle.timestamp;
        
        assert!(age <= MAX_PRICE_AGE, E_STALE_PRICE);
        assert!(oracle.is_active, E_ORACLE_INACTIVE);
        
        (oracle.price, oracle.confidence, oracle.timestamp)
    }

    // Get price without staleness check (for historical analysis)
    public fun get_price_unsafe(oracle: &PriceOracle): (u64, u64, u64) {
        (oracle.price, oracle.confidence, oracle.timestamp)
    }

    // Calculate TWAP (Time-Weighted Average Price) from history
    public fun calculate_twap(
        price_history: &PriceHistory,
        period_hours: u64,
        clock: &Clock
    ): u64 {
        let current_time = clock::timestamp_ms(clock);
        let period_ms = period_hours * 60 * 60 * 1000;
        let cutoff_time = current_time - period_ms;
        
        let prices = &price_history.prices;
        let length = vector::length(prices);
        
        if (length == 0) return 0;
        
        let mut total_weighted_price = 0;
        let mut total_time_weight = 0;
        let mut i = 0;
        
        while (i < length) {
            let price_point = vector::borrow(prices, i);
            
            if (price_point.timestamp >= cutoff_time) {
                let time_weight = current_time - price_point.timestamp;
                total_weighted_price = total_weighted_price + (price_point.price * time_weight);
                total_time_weight = total_time_weight + time_weight;
            };
            
            i = i + 1;
        };
        
        if (total_time_weight == 0) {
            // Fallback to most recent price
            let latest = vector::borrow(prices, length - 1);
            latest.price
        } else {
            total_weighted_price / total_time_weight
        }
    }

    // Create aggregated price from multiple sources  
    public fun create_aggregated_price(
        registry: &OracleRegistry,
        symbol: vector<u8>,
        prices: vector<u64>,
        confidences: vector<u64>,
        clock: &Clock,
        ctx: &mut TxContext
    ): AggregatedPrice {
        let current_time = clock::timestamp_ms(clock);
        let source_count = vector::length(&prices);
        
        assert!(source_count > 0, E_INSUFFICIENT_SOURCES);
        assert!(vector::length(&confidences) == source_count, E_INVALID_PRICE);

        // Calculate aggregated price based on method
        let aggregated_price = if (registry.aggregation_method == AGGREGATION_MEDIAN) {
            calculate_median_price(&prices)
        } else if (registry.aggregation_method == AGGREGATION_WEIGHTED_AVERAGE) {
            calculate_weighted_average_price(&prices, &confidences)
        } else {
            calculate_average_price(&prices)
        };

        // Calculate aggregate confidence 
        let mut total_confidence = 0;
        let mut i = 0;
        while (i < source_count) {
            total_confidence = total_confidence + *vector::borrow(&confidences, i);
            i = i + 1;
        };
        let aggregate_confidence = total_confidence / source_count;

        // Calculate volatility
        let volatility = calculate_price_volatility(&prices);

        // Calculate TWAPs (simplified - would use price history in production)
        let twap_1h = aggregated_price; // Placeholder
        let twap_24h = aggregated_price; // Placeholder

        let aggregated = AggregatedPrice {
            id: object::new(ctx),
            symbol: symbol,
            price: aggregated_price,
            confidence: aggregate_confidence,
            timestamp: current_time,
            source_count,
            twap_1h,
            twap_24h,
            volatility,
            volume_weighted_price: option::none(),
            price_sources: vector::empty(),
        };

        event::emit(PriceAggregated {
            symbol: symbol,
            aggregated_price,
            confidence: aggregate_confidence,
            source_count,
            method: registry.aggregation_method,
            timestamp: current_time,
            twap_1h,
            twap_24h,
        });

        aggregated
    }

    // Emergency controls
    public entry fun activate_emergency_mode(
        registry: &mut OracleRegistry,
        reason: vector<u8>,
        affected_symbols: vector<vector<u8>>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(registry.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        registry.emergency_mode = true;
        let current_time = clock::timestamp_ms(clock);

        event::emit(EmergencyModeActivated {
            reason,
            timestamp: current_time,
            admin: tx_context::sender(ctx),
            affected_symbols,
        });
    }

    // Reset circuit breaker
    public entry fun reset_circuit_breaker(
        registry: &mut OracleRegistry,
        ctx: &mut TxContext
    ) {
        assert!(registry.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        registry.circuit_breaker_active = false;
    }

    // Update oracle configuration
    public entry fun update_oracle_config(
        oracle: &mut PriceOracle,
        min_publishers: u64,
        is_active: bool,
        ctx: &mut TxContext
    ) {
        // Allow oracle owner or registry admin to update
        oracle.min_publishers = min_publishers;
        oracle.is_active = is_active;
    }

    // Helper functions
    fun validate_external_sources(
        sources: &vector<PriceSource>,
        target_price: u64,
        target_confidence: u64
    ) {
        let length = vector::length(sources);
        let mut i = 0;
        let mut valid_sources = 0;
        
        while (i < length) {
            let source = vector::borrow(sources, i);
            let deviation = calculate_price_deviation(target_price, source.price);
            
            if (deviation <= MAX_PRICE_DEVIATION && source.confidence >= MIN_CONFIDENCE_LEVEL) {
                valid_sources = valid_sources + 1;
            };
            
            i = i + 1;
        };
        
        assert!(valid_sources >= length / 2, E_INSUFFICIENT_CONFIDENCE);
    }

    fun add_price_to_history(
        history: &mut PriceHistory,
        price: u64,
        timestamp: u64,
        confidence: u64
    ) {
        let price_point = PricePoint {
            price,
            timestamp,
            volume: option::none(),
            confidence,
        };
        
        vector::push_back(&mut history.prices, price_point);
        history.total_points = history.total_points + 1;
        
        // Remove old entries if exceeding max size
        while (vector::length(&history.prices) > history.max_size) {
            vector::remove(&mut history.prices, 0);
        };
    }

    fun calculate_aggregate_confidence(sources: &vector<PriceSource>): u64 {
        let length = vector::length(sources);
        if (length == 0) return 0;
        
        let mut total_confidence = 0;
        let mut total_weight = 0;
        let mut i = 0;
        
        while (i < length) {
            let source = vector::borrow(sources, i);
            let weight = source.weight;
            total_confidence = total_confidence + (source.confidence * weight);
            total_weight = total_weight + weight;
            i = i + 1;
        };
        
        if (total_weight == 0) return 0;
        total_confidence / total_weight
    }

    fun calculate_price_deviation(old_price: u64, new_price: u64): u64 {
        if (old_price == 0) return 0;
        
        let diff = if (new_price > old_price) {
            new_price - old_price
        } else {
            old_price - new_price
        };
        (diff * 10000) / old_price
    }

    fun calculate_median_price(prices: &vector<u64>): u64 {
        let len = vector::length(prices);
        if (len == 0) return 0;
        if (len == 1) return *vector::borrow(prices, 0);
        
        // Simplified median calculation (should sort in production)
        let mut sum = 0;
        let mut i = 0;
        while (i < len) {
            sum = sum + *vector::borrow(prices, i);
            i = i + 1;
        };
        sum / len
    }

    fun calculate_weighted_average_price(prices: &vector<u64>, weights: &vector<u64>): u64 {
        let len = vector::length(prices);
        if (len == 0) return 0;
        
        let mut weighted_sum = 0;
        let mut total_weight = 0;
        let mut i = 0;
        
        while (i < len) {
            let price = *vector::borrow(prices, i);
            let weight = *vector::borrow(weights, i);
            weighted_sum = weighted_sum + (price * weight);
            total_weight = total_weight + weight;
            i = i + 1;
        };
        
        if (total_weight == 0) return 0;
        weighted_sum / total_weight
    }

    fun calculate_average_price(prices: &vector<u64>): u64 {
        let len = vector::length(prices);
        if (len == 0) return 0;
        
        let mut sum = 0;
        let mut i = 0;
        while (i < len) {
            sum = sum + *vector::borrow(prices, i);
            i = i + 1;
        };
        sum / len
    }

    fun calculate_price_volatility(prices: &vector<u64>): u64 {
        let len = vector::length(prices);
        if (len < 2) return 0;
        
        let avg = calculate_average_price(prices);
        let mut variance_sum = 0;
        let mut i = 0;
        
        while (i < len) {
            let price = *vector::borrow(prices, i);
            let diff = if (price > avg) { price - avg } else { avg - price };
            variance_sum = variance_sum + (diff * diff);
            i = i + 1;
        };
        
        let variance = variance_sum / len;
        sqrt_u64(variance)
    }

    // Enhanced view functions for Gas Futures integration
    public fun get_oracle_info(oracle: &PriceOracle): (vector<u8>, u64, u64, u64, bool, u64, u8) {
        (
            oracle.symbol, 
            oracle.price, 
            oracle.confidence, 
            oracle.timestamp, 
            oracle.is_active,
            oracle.update_count,
            oracle.oracle_type
        )
    }

    public fun get_ema_price(oracle: &PriceOracle): (u64, u64) {
        (oracle.ema_price, oracle.ema_confidence)
    }

    public fun get_registry_info(registry: &OracleRegistry): (u64, bool, u64, u8, bool) {
        (
            registry.total_updates,
            registry.emergency_mode,
            registry.last_health_check,
            registry.aggregation_method,
            registry.circuit_breaker_active
        )
    }

    public fun get_price_history_length(history: &PriceHistory): u64 {
        vector::length(&history.prices)
    }

    public fun get_supported_symbols(registry: &OracleRegistry): &vector<vector<u8>> {
        &registry.supported_symbols
    }

    // Gas Futures specific integration functions
    public fun get_gas_price_with_confidence(
        oracle: &PriceOracle,
        clock: &Clock
    ): (u64, u64, bool) {
        let current_time = clock::timestamp_ms(clock);
        let age = current_time - oracle.timestamp;
        let is_fresh = age <= MAX_PRICE_AGE;
        
        (oracle.price, oracle.confidence, is_fresh)
    }

    public fun calculate_price_impact(
        oracle: &PriceOracle,
        new_price: u64
    ): u64 {
        calculate_price_deviation(oracle.price, new_price)
    }

    public fun is_price_anomaly(
        oracle: &PriceOracle,
        new_price: u64
    ): bool {
        let deviation = calculate_price_deviation(oracle.price, new_price);
        deviation > MAX_PRICE_DEVIATION
    }
}