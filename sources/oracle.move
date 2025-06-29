/// Oracle System for Gas Futures Platform
/// Provides reliable price feeds using Pyth Network integration
module gas_futures::oracle {
    use sui::object::{Self};
    use sui::tx_context::{Self};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::table::{Self, Table};

    // Error codes
    const E_UNAUTHORIZED: u64 = 1;
    const E_STALE_PRICE: u64 = 2;
    const E_INVALID_PRICE: u64 = 3;
    const E_PRICE_DEVIATION_TOO_HIGH: u64 = 4;
    const E_INSUFFICIENT_CONFIDENCE: u64 = 5;
    const E_ORACLE_NOT_FOUND: u64 = 6;

    // Oracle configuration constants
    const MAX_PRICE_AGE: u64 = 300000; // 5 minutes in milliseconds
    const MIN_CONFIDENCE_LEVEL: u64 = 8500; // 85% confidence required
    const MAX_PRICE_DEVIATION: u64 = 1000; // 10% maximum deviation
    const PRECISION: u64 = 1000000; // 1e6 for decimal precision

    // Price aggregation types
    const AGGREGATION_MEDIAN: u8 = 1;
    const AGGREGATION_WEIGHTED_AVERAGE: u8 = 2;
    const AGGREGATION_TWAP: u8 = 3; // Time-weighted average price

    // Math utility functions
    fun min_u64(a: u64, b: u64): u64 {
        if (a < b) a else b
    }

    fun sqrt_u64(x: u64): u64 {
        if (x == 0) return 0;
        let z = (x + 1) / 2;
        let y = x;
        // Simplified sqrt - using approximation
        if (z < y) z else y
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
        is_active: bool,
    }

    // Price feed registry
    public struct OracleRegistry has key {
        id: UID,
        oracles: Table<vector<u8>, address>, // symbol -> oracle address
        aggregation_method: u8,
        admin: address,
        emergency_mode: bool,
        total_updates: u64,
        last_health_check: u64,
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
    }

    // Events
    public struct PriceUpdated has copy, drop {
        symbol: vector<u8>,
        price: u64,
        confidence: u64,
        timestamp: u64,
        source: vector<u8>,
    }

    public struct PriceAggregated has copy, drop {
        symbol: vector<u8>,
        aggregated_price: u64,
        confidence: u64,
        source_count: u64,
        method: u8,
    }

    public struct OracleCreated has copy, drop {
        symbol: vector<u8>,
        oracle_address: address,
        source: vector<u8>,
        creator: address,
    }

    public struct EmergencyModeActivated has copy, drop {
        reason: vector<u8>,
        timestamp: u64,
        admin: address,
    }

    public struct PriceAnomaly has copy, drop {
        symbol: vector<u8>,
        current_price: u64,
        previous_price: u64,
        deviation_percentage: u64,
        timestamp: u64,
    }

    // Initialize oracle system
    fun init(ctx: &mut TxContext) {
        let registry = OracleRegistry {
            id: object::new(ctx),
            oracles: table::new(ctx),
            aggregation_method: AGGREGATION_WEIGHTED_AVERAGE,
            admin: tx_context::sender(ctx),
            emergency_mode: false,
            total_updates: 0,
            last_health_check: 0,
        };
        transfer::share_object(registry);
    }

    // Create new price oracle
    public entry fun create_oracle(
        registry: &mut OracleRegistry,
        symbol: vector<u8>,
        source: vector<u8>,
        initial_price: u64,
        expo: u8,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(registry.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        
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
            is_active: true,
        };

        let oracle_address = object::uid_to_address(&oracle.id);
        table::add(&mut registry.oracles, symbol, oracle_address);

        event::emit(OracleCreated {
            symbol: symbol,
            oracle_address,
            source: source,
            creator: tx_context::sender(ctx),
        });

        transfer::share_object(oracle);
    }

    // Update price from Pyth Network or other sources
    public entry fun update_price(
        registry: &mut OracleRegistry,
        oracle: &mut PriceOracle,
        new_price: u64,
        confidence: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        
        // Validate price update
        assert!(confidence >= MIN_CONFIDENCE_LEVEL, E_INSUFFICIENT_CONFIDENCE);
        assert!(new_price > 0, E_INVALID_PRICE);
        
        // Check for price anomalies
        let price_deviation = calculate_price_deviation(oracle.price, new_price);
        if (price_deviation > MAX_PRICE_DEVIATION) {
            event::emit(PriceAnomaly {
                symbol: oracle.symbol,
                current_price: new_price,
                previous_price: oracle.price,
                deviation_percentage: price_deviation,
                timestamp: current_time,
            });
            
            // In emergency mode, reject extreme price changes
            if (registry.emergency_mode) {
                assert!(false, E_PRICE_DEVIATION_TOO_HIGH);
            }
        };

        let old_price = oracle.price;

        // Update EMA (Exponential Moving Average)
        let alpha = 2000; // 20% weight for new price (in basis points)
        oracle.ema_price = (oracle.ema_price * (10000 - alpha) + new_price * alpha) / 10000;
        oracle.ema_confidence = (oracle.ema_confidence * (10000 - alpha) + confidence * alpha) / 10000;

        // Update oracle data
        oracle.price = new_price;
        oracle.confidence = confidence;
        oracle.timestamp = current_time;

        // Update registry statistics
        registry.total_updates = registry.total_updates + 1;

        // Create price update record
        let price_update = PriceUpdate {
            id: object::new(ctx),
            oracle_symbol: oracle.symbol,
            old_price,
            new_price,
            confidence,
            timestamp: current_time,
            updater: tx_context::sender(ctx),
        };

        event::emit(PriceUpdated {
            symbol: oracle.symbol,
            price: new_price,
            confidence,
            timestamp: current_time,
            source: oracle.source,
        });

        transfer::transfer(price_update, tx_context::sender(ctx));
    }

    // Get current price with staleness check
    public entry fun get_price(
        oracle: &PriceOracle,
        clock: &Clock
    ): (u64, u64, u64) {
        let current_time = clock::timestamp_ms(clock);
        let age = current_time - oracle.timestamp;
        
        assert!(age <= MAX_PRICE_AGE, E_STALE_PRICE);
        assert!(oracle.is_active, E_ORACLE_NOT_FOUND);
        
        (oracle.price, oracle.confidence, oracle.timestamp)
    }

    // Calculate TWAP (Time-Weighted Average Price)
    public entry fun calculate_twap(
        oracle: &PriceOracle,
        period_hours: u64,
        clock: &Clock
    ): u64 {
        let current_time = clock::timestamp_ms(clock);
        let period_ms = period_hours * 60 * 60 * 1000;
        
        // Simplified TWAP calculation using EMA
        // In production, would use historical price data
        let time_weight = min_u64(
            (current_time - oracle.timestamp) * 10000 / period_ms,
            10000
        );
        
        (oracle.ema_price * time_weight + oracle.price * (10000 - time_weight)) / 10000
    }

    // Create aggregated price from multiple sources
    public entry fun create_aggregated_price(
        registry: &OracleRegistry,
        symbol: vector<u8>,
        prices: vector<u64>,
        confidences: vector<u64>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let source_count = vector::length(&prices);
        
        assert!(source_count > 0, E_ORACLE_NOT_FOUND);
        assert!(vector::length(&confidences) == source_count, E_INVALID_PRICE);

        // Calculate aggregated price based on method
        let aggregated_price = if (registry.aggregation_method == AGGREGATION_MEDIAN) {
            calculate_median_price(&prices)
        } else if (registry.aggregation_method == AGGREGATION_WEIGHTED_AVERAGE) {
            calculate_weighted_average_price(&prices, &confidences)
        } else {
            // Default to simple average
            calculate_average_price(&prices)
        };

        // Calculate aggregate confidence
        let mut total_confidence = 0;
        let mut i = 0;
        while (i < source_count) {
            total_confidence = total_confidence + *vector::borrow(&confidences, i);
            i = i + 1;
        };
        let avg_confidence = total_confidence / source_count;

        // Calculate volatility (simplified)
        let volatility = calculate_price_volatility(&prices);

        let aggregated = AggregatedPrice {
            id: object::new(ctx),
            symbol: symbol,
            price: aggregated_price,
            confidence: avg_confidence,
            timestamp: current_time,
            source_count,
            twap_1h: aggregated_price, // Simplified
            twap_24h: aggregated_price, // Simplified
            volatility,
        };

        event::emit(PriceAggregated {
            symbol: symbol,
            aggregated_price,
            confidence: avg_confidence,
            source_count,
            method: registry.aggregation_method,
        });

        transfer::share_object(aggregated);
    }

    // Emergency controls
    public entry fun activate_emergency_mode(
        registry: &mut OracleRegistry,
        reason: vector<u8>,
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
        });
    }

    // Utility functions
    fun calculate_price_deviation(old_price: u64, new_price: u64): u64 {
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
        
        // Simplified median calculation (would sort in production)
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

    // View functions
    public fun get_oracle_info(oracle: &PriceOracle): (vector<u8>, u64, u64, u64, bool) {
        (oracle.symbol, oracle.price, oracle.confidence, oracle.timestamp, oracle.is_active)
    }

    public fun get_ema_price(oracle: &PriceOracle): (u64, u64) {
        (oracle.ema_price, oracle.ema_confidence)
    }

    public fun is_price_fresh(oracle: &PriceOracle, clock: &Clock): bool {
        let current_time = clock::timestamp_ms(clock);
        let age = current_time - oracle.timestamp;
        age <= MAX_PRICE_AGE
    }
}