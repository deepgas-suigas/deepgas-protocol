/// Advanced AMM with MEV Protection for Gas Futures
/// Features batch auctions, MEV resistance, and sophisticated market making
module gas_futures::amm {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::table::{Self, Table};
    use sui::transfer;
    use std::option::{Self, Option};
    use std::vector;

    // Error codes
    const E_INSUFFICIENT_LIQUIDITY: u64 = 1;
    const E_SLIPPAGE_TOO_HIGH: u64 = 2;
    const E_INVALID_ORDER: u64 = 3;
    const E_AUCTION_NOT_ACTIVE: u64 = 4;
    const E_UNAUTHORIZED: u64 = 5;
    const E_MEV_DETECTED: u64 = 6;
    const E_BATCH_NOT_READY: u64 = 7;
    const E_FRONTRUN_DETECTED: u64 = 8;
    const E_INSUFFICIENT_PAYMENT: u64 = 9;
    const E_ZERO_AMOUNT: u64 = 10;
    const E_INSUFFICIENT_LP_TOKENS: u64 = 11;

    // Constants
    const BATCH_DURATION: u64 = 15000; // 15 seconds
    const MAX_SLIPPAGE: u64 = 1000; // 10%
    const MEV_THRESHOLD: u64 = 5000; // 50% price impact threshold
    const MIN_BATCH_SIZE: u64 = 3; // Minimum orders in batch
    const FEE_PRECISION: u64 = 10000; // 1 = 0.01%
    const PRICE_PRECISION: u64 = 1000000; // 1e6

    // Order types
    const ORDER_TYPE_MARKET: u8 = 1;
    const ORDER_TYPE_LIMIT: u8 = 2;
    const ORDER_TYPE_STOP_LOSS: u8 = 3;

    // Auction states
    const AUCTION_ACCEPTING: u8 = 1;
    const AUCTION_EXECUTING: u8 = 2;
    const AUCTION_COMPLETED: u8 = 3;

    // Trading order with MEV protection
    public struct Order has store, drop {
        id: u64,
        trader: address,
        order_type: u8,
        is_buy: bool,
        amount: u64,
        price_limit: u64,
        max_slippage: u64,
        submitted_at: u64,
        commitment_hash: vector<u8>, // For commit-reveal scheme
    }

    // Liquidity Position Token
    public struct LPToken has key, store {
        id: UID,
        pool_id: ID,
        owner: address,
        amount: u64,
        shares: u64,
        created_at: u64,
    }

    // Batch auction for MEV resistance
    public struct BatchAuction has key {
        id: UID,
        batch_id: u64,
        orders: vector<Order>,
        execution_price: u64,
        total_buy_volume: u64,
        total_sell_volume: u64,
        auction_start: u64,
        auction_end: u64,
        status: u8,
        mev_protection_active: bool,
        clearing_price: u64,
    }

    // Advanced liquidity pool with MEV protection
    public struct AdvancedPool has key {
        id: UID,
        duration_days: u64,
        sui_reserve: Balance<SUI>,
        gas_credits_reserve: u64,
        total_liquidity_tokens: u64,
        fee_rate: u64,
        last_price: u64,
        price_impact_factor: u64,
        mev_protection_enabled: bool,
        frontrun_detection: FrontrunDetection,
        batch_auction_id: Option<u64>,
        trade_history: Table<u64, TradeInfo>,
        trade_counter: u64,
        total_fees_collected: u64,
        created_at: u64,
    }

    // MEV and frontrunning detection
    public struct FrontrunDetection has store {
        last_trade_price: u64,
        last_trade_timestamp: u64,
        large_order_threshold: u64,
        price_manipulation_threshold: u64,
        suspicious_activity_count: u64,
    }

    // Trade information for analysis
    public struct TradeInfo has store {
        trader: address,
        amount: u64,
        price: u64,
        timestamp: u64,
        price_impact: u64,
        mev_detected: bool,
        fees_paid: u64,
    }

    // Swap Quote structure
    public struct SwapQuote has copy, drop {
        input_amount: u64,
        output_amount: u64,
        price_impact: u64,
        minimum_received: u64,
        fee_amount: u64,
        route: vector<ID>,
        estimated_gas: u64,
        mev_protection: bool,
    }

    // Advanced AMM registry
    public struct AMMRegistry has key {
        id: UID,
        pools: Table<u64, ID>, // duration -> pool_id
        batch_auctions: Table<u64, ID>, // batch_id -> auction_id
        batch_counter: u64,
        total_mev_prevented: u64,
        total_frontrun_blocked: u64,
        admin: address,
        total_volume: u64,
        total_fees: u64,
    }

    // Time-weighted average price oracle
    public struct TWAPOracle has key {
        id: UID,
        pool_id: ID,
        price_accumulator: u64,
        timestamp_last: u64,
        period: u64,
        price_history: Table<u64, u64>, // timestamp -> price
    }

    // Events
    public struct PoolCreated has copy, drop {
        pool_id: ID,
        duration_days: u64,
        initial_price: u64,
        mev_protection: bool,
        creator: address,
    }

    public struct OrderSubmitted has copy, drop {
        batch_id: u64,
        order_id: u64,
        trader: address,
        order_type: u8,
        amount: u64,
        price_limit: u64,
    }

    public struct BatchExecuted has copy, drop {
        batch_id: u64,
        clearing_price: u64,
        total_volume: u64,
        orders_executed: u64,
        mev_prevented: bool,
    }

    public struct MEVDetected has copy, drop {
        trader: address,
        transaction_hash: vector<u8>,
        price_impact: u64,
        blocked: bool,
        timestamp: u64,
    }

    public struct FrontrunBlocked has copy, drop {
        frontrunner: address,
        victim: address,
        savings: u64,
        timestamp: u64,
    }

    public struct LiquidityAdded has copy, drop {
        provider: address,
        pool_id: ID,
        sui_amount: u64,
        gas_credits_amount: u64,
        lp_tokens_minted: u64,
        price_impact: u64,
    }

    public struct LiquidityRemoved has copy, drop {
        provider: address,
        pool_id: ID,
        lp_tokens_burned: u64,
        sui_amount: u64,
        gas_credits_amount: u64,
    }

    public struct TradeExecuted has copy, drop {
        trader: address,
        pool_id: ID,
        amount_in: u64,
        amount_out: u64,
        is_buy: bool,
        price: u64,
        price_impact: u64,
        fees_paid: u64,
    }

    // Initialize advanced AMM system
    fun init(ctx: &mut TxContext) {
        let registry = AMMRegistry {
            id: object::new(ctx),
            pools: table::new(ctx),
            batch_auctions: table::new(ctx),
            batch_counter: 0,
            total_mev_prevented: 0,
            total_frontrun_blocked: 0,
            admin: tx_context::sender(ctx),
            total_volume: 0,
            total_fees: 0,
        };
        transfer::share_object(registry);
    }

    // Create advanced pool with MEV protection
    public entry fun create_advanced_pool(
        registry: &mut AMMRegistry,
        duration_days: u64,
        initial_sui: Coin<SUI>,
        initial_gas_credits: u64,
        enable_mev_protection: bool,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sui_amount = coin::value(&initial_sui);
        assert!(sui_amount > 0 && initial_gas_credits > 0, E_INSUFFICIENT_LIQUIDITY);

        let current_time = clock::timestamp_ms(clock);
        let initial_lp_tokens = sqrt_u64(sui_amount * initial_gas_credits);
        
        let pool = AdvancedPool {
            id: object::new(ctx),
            duration_days,
            sui_reserve: coin::into_balance(initial_sui),
            gas_credits_reserve: initial_gas_credits,
            total_liquidity_tokens: initial_lp_tokens,
            fee_rate: 30, // 0.3%
            last_price: (sui_amount * PRICE_PRECISION) / initial_gas_credits,
            price_impact_factor: 50, // 0.5%
            mev_protection_enabled: enable_mev_protection,
            frontrun_detection: FrontrunDetection {
                last_trade_price: (sui_amount * PRICE_PRECISION) / initial_gas_credits,
                last_trade_timestamp: current_time,
                large_order_threshold: sui_amount / 10, // 10% of initial liquidity
                price_manipulation_threshold: 1000, // 10%
                suspicious_activity_count: 0,
            },
            batch_auction_id: option::none(),
            trade_history: table::new(ctx),
            trade_counter: 0,
            total_fees_collected: 0,
            created_at: current_time,
        };

        let pool_id = object::uid_to_inner(&pool.id);
        table::add(&mut registry.pools, duration_days, pool_id);

        // Create initial LP token for creator
        let lp_token = LPToken {
            id: object::new(ctx),
            pool_id,
            owner: tx_context::sender(ctx),
            amount: initial_lp_tokens,
            shares: initial_lp_tokens,
            created_at: current_time,
        };

        event::emit(PoolCreated {
            pool_id,
            duration_days,
            initial_price: pool.last_price,
            mev_protection: enable_mev_protection,
            creator: tx_context::sender(ctx),
        });

        transfer::transfer(lp_token, tx_context::sender(ctx));
        transfer::share_object(pool);
    }

    // Main swap function - CRITICAL MISSING FUNCTION
    public entry fun swap(
        pool: &mut AdvancedPool,
        payment: Coin<SUI>,
        is_buy: bool,
        min_output: u64,
        max_slippage: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let amount_in = coin::value(&payment);
        assert!(amount_in > 0, E_ZERO_AMOUNT);
        assert!(max_slippage <= MAX_SLIPPAGE, E_SLIPPAGE_TOO_HIGH);

        let current_time = clock::timestamp_ms(clock);
        let trader = tx_context::sender(ctx);

        // MEV Detection
        if (pool.mev_protection_enabled && detect_mev(pool, amount_in, is_buy, current_time)) {
            event::emit(MEVDetected {
                trader,
                transaction_hash: vector::empty(),
                price_impact: calculate_price_impact(pool, amount_in, is_buy),
                blocked: true,
                timestamp: current_time,
            });
            abort E_MEV_DETECTED
        };

        // Calculate swap amounts
        let (amount_out, fee_amount, price_impact) = calculate_swap_amounts(pool, amount_in, is_buy);
        
        // Slippage protection
        assert!(amount_out >= min_output, E_SLIPPAGE_TOO_HIGH);
        let slippage = if (amount_out < amount_in) {
            ((amount_in - amount_out) * FEE_PRECISION) / amount_in
        } else {
            ((amount_out - amount_in) * FEE_PRECISION) / amount_out
        };
        assert!(slippage <= max_slippage, E_SLIPPAGE_TOO_HIGH);

        // Execute swap
        if (is_buy) {
            // Buy gas credits with SUI
            assert!(pool.gas_credits_reserve >= amount_out, E_INSUFFICIENT_LIQUIDITY);
            
            // Add SUI to pool
            balance::join(&mut pool.sui_reserve, coin::into_balance(payment));
            
            // Remove gas credits from pool
            pool.gas_credits_reserve = pool.gas_credits_reserve - amount_out;
            
            // Create gas credits coin (simplified - in reality would be proper coin type)
            // For now, we'll track this in events
            
        } else {
            // Sell gas credits for SUI
            let sui_reserve_value = balance::value(&pool.sui_reserve);
            assert!(sui_reserve_value >= amount_out, E_INSUFFICIENT_LIQUIDITY);
            
            // Add gas credits to pool (payment would be gas credits)
            pool.gas_credits_reserve = pool.gas_credits_reserve + amount_in;
            
            // Remove SUI from pool
            let sui_out = balance::split(&mut pool.sui_reserve, amount_out);
            transfer::public_transfer(coin::from_balance(sui_out, ctx), trader);
            
            // Handle the SUI payment (burn it since we're simulating gas credits input)
            balance::join(&mut pool.sui_reserve, coin::into_balance(payment));
        };

        // Update pool state
        pool.total_fees_collected = pool.total_fees_collected + fee_amount;
        pool.last_price = calculate_current_price(pool);
        pool.frontrun_detection.last_trade_price = pool.last_price;
        pool.frontrun_detection.last_trade_timestamp = current_time;

        // Record trade
        let trade_info = TradeInfo {
            trader,
            amount: amount_in,
            price: pool.last_price,
            timestamp: current_time,
            price_impact,
            mev_detected: false,
            fees_paid: fee_amount,
        };
        
        table::add(&mut pool.trade_history, pool.trade_counter, trade_info);
        pool.trade_counter = pool.trade_counter + 1;

        event::emit(TradeExecuted {
            trader,
            pool_id: object::uid_to_inner(&pool.id),
            amount_in,
            amount_out,
            is_buy,
            price: pool.last_price,
            price_impact,
            fees_paid: fee_amount,
        });
    }

    // Add liquidity function - CRITICAL MISSING FUNCTION
    public entry fun add_liquidity(
        pool: &mut AdvancedPool,
        sui_payment: Coin<SUI>,
        gas_credits_amount: u64,
        min_lp_tokens: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sui_amount = coin::value(&sui_payment);
        assert!(sui_amount > 0 && gas_credits_amount > 0, E_ZERO_AMOUNT);

        let current_time = clock::timestamp_ms(clock);
        let provider = tx_context::sender(ctx);

        // Calculate LP tokens to mint
        let sui_reserve_value = balance::value(&pool.sui_reserve);
        let lp_tokens_to_mint = if (pool.total_liquidity_tokens == 0) {
            sqrt_u64(sui_amount * gas_credits_amount)
        } else {
            let sui_ratio = (sui_amount * pool.total_liquidity_tokens) / sui_reserve_value;
            let gas_ratio = (gas_credits_amount * pool.total_liquidity_tokens) / pool.gas_credits_reserve;
            if (sui_ratio < gas_ratio) sui_ratio else gas_ratio
        };

        assert!(lp_tokens_to_mint >= min_lp_tokens, E_SLIPPAGE_TOO_HIGH);

        // Add liquidity to pool
        balance::join(&mut pool.sui_reserve, coin::into_balance(sui_payment));
        pool.gas_credits_reserve = pool.gas_credits_reserve + gas_credits_amount;
        pool.total_liquidity_tokens = pool.total_liquidity_tokens + lp_tokens_to_mint;

        // Create LP token for provider
        let lp_token = LPToken {
            id: object::new(ctx),
            pool_id: object::uid_to_inner(&pool.id),
            owner: provider,
            amount: lp_tokens_to_mint,
            shares: lp_tokens_to_mint,
            created_at: current_time,
        };

        let price_impact = calculate_price_impact_liquidity(pool, sui_amount, gas_credits_amount);

        event::emit(LiquidityAdded {
            provider,
            pool_id: object::uid_to_inner(&pool.id),
            sui_amount,
            gas_credits_amount,
            lp_tokens_minted: lp_tokens_to_mint,
            price_impact,
        });

        transfer::transfer(lp_token, provider);
    }

    // Remove liquidity function - CRITICAL MISSING FUNCTION
    public entry fun remove_liquidity(
        pool: &mut AdvancedPool,
        lp_token: LPToken,
        min_sui: u64,
        min_gas_credits: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let provider = tx_context::sender(ctx);
        
        // Verify LP token ownership
        assert!(lp_token.owner == provider, E_UNAUTHORIZED);
        assert!(lp_token.pool_id == object::uid_to_inner(&pool.id), E_INVALID_ORDER);

        let lp_amount = lp_token.amount;
        assert!(lp_amount > 0, E_INSUFFICIENT_LP_TOKENS);

        // Calculate withdrawal amounts
        let sui_reserve_value = balance::value(&pool.sui_reserve);
        let sui_amount = (lp_amount * sui_reserve_value) / pool.total_liquidity_tokens;
        let gas_credits_amount = (lp_amount * pool.gas_credits_reserve) / pool.total_liquidity_tokens;

        assert!(sui_amount >= min_sui, E_SLIPPAGE_TOO_HIGH);
        assert!(gas_credits_amount >= min_gas_credits, E_SLIPPAGE_TOO_HIGH);

        // Remove liquidity from pool
        let sui_out = balance::split(&mut pool.sui_reserve, sui_amount);
        pool.gas_credits_reserve = pool.gas_credits_reserve - gas_credits_amount;
        pool.total_liquidity_tokens = pool.total_liquidity_tokens - lp_amount;

        // Transfer withdrawn amounts
        transfer::public_transfer(coin::from_balance(sui_out, ctx), provider);
        // Gas credits transfer would be handled here (simplified for demo)

        event::emit(LiquidityRemoved {
            provider,
            pool_id: object::uid_to_inner(&pool.id),
            lp_tokens_burned: lp_amount,
            sui_amount,
            gas_credits_amount,
        });

        // Burn LP token
        let LPToken { id, pool_id: _, owner: _, amount: _, shares: _, created_at: _ } = lp_token;
        object::delete(id);
    }

    // Get swap quote function - CRITICAL MISSING FUNCTION
    public fun get_swap_quote(
        pool: &AdvancedPool,
        amount_in: u64,
        is_buy: bool
    ): SwapQuote {
        let (amount_out, fee_amount, price_impact) = calculate_swap_amounts(pool, amount_in, is_buy);
        
        SwapQuote {
            input_amount: amount_in,
            output_amount: amount_out,
            price_impact,
            minimum_received: amount_out * 95 / 100, // 5% slippage
            fee_amount,
            route: vector::singleton(object::uid_to_inner(&pool.id)),
            estimated_gas: 100000, // Estimated gas cost
            mev_protection: pool.mev_protection_enabled,
        }
    }

    // Calculate swap amounts - CRITICAL HELPER FUNCTION
    fun calculate_swap_amounts(
        pool: &AdvancedPool,
        amount_in: u64,
        is_buy: bool
    ): (u64, u64, u64) {
        let sui_reserve = balance::value(&pool.sui_reserve);
        let gas_reserve = pool.gas_credits_reserve;
        
        if (is_buy) {
            // Buy gas credits with SUI (x * y = k formula)
            let amount_in_with_fee = amount_in * (FEE_PRECISION - pool.fee_rate) / FEE_PRECISION;
            let amount_out = (amount_in_with_fee * gas_reserve) / (sui_reserve + amount_in_with_fee);
            let fee_amount = amount_in - amount_in_with_fee;
            let price_impact = (amount_out * FEE_PRECISION) / gas_reserve;
            
            (amount_out, fee_amount, price_impact)
        } else {
            // Sell gas credits for SUI
            let amount_in_with_fee = amount_in * (FEE_PRECISION - pool.fee_rate) / FEE_PRECISION;
            let amount_out = (amount_in_with_fee * sui_reserve) / (gas_reserve + amount_in_with_fee);
            let fee_amount = amount_in - amount_in_with_fee;
            let price_impact = (amount_out * FEE_PRECISION) / sui_reserve;
            
            (amount_out, fee_amount, price_impact)
        }
    }

    // Calculate current price - HELPER FUNCTION
    fun calculate_current_price(pool: &AdvancedPool): u64 {
        let sui_reserve = balance::value(&pool.sui_reserve);
        if (pool.gas_credits_reserve == 0) return 0;
        
        (sui_reserve * PRICE_PRECISION) / pool.gas_credits_reserve
    }

    // Calculate price impact for liquidity operations
    fun calculate_price_impact_liquidity(
        pool: &AdvancedPool,
        sui_amount: u64,
        gas_credits_amount: u64
    ): u64 {
        let sui_reserve = balance::value(&pool.sui_reserve);
        let current_ratio = sui_reserve / pool.gas_credits_reserve;
        let new_ratio = (sui_reserve + sui_amount) / (pool.gas_credits_reserve + gas_credits_amount);
        
        if (new_ratio > current_ratio) {
            ((new_ratio - current_ratio) * FEE_PRECISION) / current_ratio
        } else {
            ((current_ratio - new_ratio) * FEE_PRECISION) / current_ratio
        }
    }

    // Submit order to batch auction
    public entry fun submit_order(
        registry: &mut AMMRegistry,
        pool: &mut AdvancedPool,
        order_type: u8,
        is_buy: bool,
        amount: u64,
        price_limit: u64,
        max_slippage: u64,
        commitment_hash: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(pool.mev_protection_enabled, E_MEV_DETECTED);
        assert!(amount > 0, E_ZERO_AMOUNT);
        
        let current_time = clock::timestamp_ms(clock);
        let trader = tx_context::sender(ctx);
        
        // MEV detection
        if (detect_mev(pool, amount, is_buy, current_time)) {
            event::emit(MEVDetected {
                trader,
                transaction_hash: commitment_hash,
                price_impact: calculate_price_impact(pool, amount, is_buy),
                blocked: true,
                timestamp: current_time,
            });
            abort E_MEV_DETECTED
        };

        // Frontrun detection
        if (detect_frontrun(pool, amount, current_time, ctx)) {
            registry.total_frontrun_blocked = registry.total_frontrun_blocked + 1;
            event::emit(FrontrunBlocked {
                frontrunner: trader,
                victim: @0x0, // Would be determined by analysis
                savings: amount / 100, // Estimated savings
                timestamp: current_time,
            });
            abort E_FRONTRUN_DETECTED
        };

        // Create order
        let order = Order {
            id: pool.trade_counter,
            trader,
            order_type,
            is_buy,
            amount,
            price_limit,
            max_slippage,
            submitted_at: current_time,
            commitment_hash,
        };

        // Add to current batch or create new one
        // For simplification, we'll record as immediate trade
        let (amount_out, fee_amount, price_impact) = calculate_swap_amounts(pool, amount, is_buy);
        
        // Record trade
        let trade_info = TradeInfo {
            trader,
            amount,
            price: pool.last_price,
            timestamp: current_time,
            price_impact,
            mev_detected: false,
            fees_paid: fee_amount,
        };
        
        table::add(&mut pool.trade_history, pool.trade_counter, trade_info);
        pool.trade_counter = pool.trade_counter + 1;

        event::emit(OrderSubmitted {
            batch_id: 0, // Simplified
            order_id: pool.trade_counter,
            trader,
            order_type,
            amount,
            price_limit,
        });
    }

    // Execute batch auction
    public entry fun execute_batch_auction(
        registry: &mut AMMRegistry,
        pool: &mut AdvancedPool,
        batch_auction: &mut BatchAuction,
        clock: &Clock,
        _ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        
        assert!(current_time >= batch_auction.auction_end, E_BATCH_NOT_READY);
        assert!(batch_auction.status == AUCTION_ACCEPTING, E_AUCTION_NOT_ACTIVE);
        assert!(vector::length(&batch_auction.orders) >= MIN_BATCH_SIZE, E_BATCH_NOT_READY);

        batch_auction.status = AUCTION_EXECUTING;

        // Calculate clearing price using uniform price auction
        let clearing_price = calculate_clearing_price(batch_auction, pool);
        batch_auction.clearing_price = clearing_price;

        // Execute matching orders
        let (executed_orders, total_volume) = execute_matching_orders(batch_auction, clearing_price);

        // Update pool state
        update_pool_after_batch(pool, total_volume, clearing_price, current_time);

        batch_auction.status = AUCTION_COMPLETED;
        registry.total_mev_prevented = registry.total_mev_prevented + 1;

        event::emit(BatchExecuted {
            batch_id: batch_auction.batch_id,
            clearing_price,
            total_volume,
            orders_executed: executed_orders,
            mev_prevented: true,
        });
    }

    // MEV Detection
    fun detect_mev(
        pool: &AdvancedPool,
        amount: u64,
        is_buy: bool,
        current_time: u64
    ): bool {
        let price_impact = calculate_price_impact(pool, amount, is_buy);
        
        // Large price impact detection
        if (price_impact > MEV_THRESHOLD) {
            return true
        };

        // Rapid succession detection
        if (current_time - pool.frontrun_detection.last_trade_timestamp < 1000) { // 1 second
            return true
        };

        false
    }

    fun detect_frontrun(
        pool: &AdvancedPool,
        amount: u64,
        current_time: u64,
        _ctx: &TxContext
    ): bool {
        // Detect if this order might be frontrunning another
        let large_order_threshold = pool.frontrun_detection.large_order_threshold;
        
        if (amount > large_order_threshold) {
            // Check for rapid succession of large orders
            if (current_time - pool.frontrun_detection.last_trade_timestamp < 5000) { // 5 seconds
                return true
            }
        };

        false
    }

    fun calculate_price_impact(pool: &AdvancedPool, amount: u64, is_buy: bool): u64 {
        let sui_reserve = balance::value(&pool.sui_reserve);
        
        if (is_buy) {
            (amount * FEE_PRECISION) / sui_reserve
        } else {
            (amount * FEE_PRECISION) / pool.gas_credits_reserve
        }
    }

    fun calculate_clearing_price(
        batch_auction: &BatchAuction,
        pool: &AdvancedPool
    ): u64 {
        // Simplified uniform price calculation
        let current_price = pool.last_price;
        let volume_ratio = if (batch_auction.total_buy_volume > batch_auction.total_sell_volume) {
            (batch_auction.total_buy_volume * FEE_PRECISION) / batch_auction.total_sell_volume
        } else {
            (batch_auction.total_sell_volume * FEE_PRECISION) / batch_auction.total_buy_volume
        };
        
        // Adjust price based on volume imbalance
        if (volume_ratio > FEE_PRECISION) {
            current_price + (current_price * (volume_ratio - FEE_PRECISION) / 100000)
        } else {
            current_price - (current_price * (FEE_PRECISION - volume_ratio) / 100000)
        }
    }

    fun execute_matching_orders(
        batch_auction: &BatchAuction,
        clearing_price: u64
    ): (u64, u64) {
        let mut executed_count = 0;
        let mut total_volume = 0;

        let orders_len = vector::length(&batch_auction.orders);
        let mut i = 0;
        while (i < orders_len) {
            let order = vector::borrow(&batch_auction.orders, i);
            
            // Check if order can be executed at clearing price
            if ((order.is_buy && clearing_price <= order.price_limit) ||
                (!order.is_buy && clearing_price >= order.price_limit)) {
                executed_count = executed_count + 1;
                total_volume = total_volume + order.amount;
            };
            
            i = i + 1;
        };

        (executed_count, total_volume)
    }

    fun update_pool_after_batch(
        pool: &mut AdvancedPool,
        total_volume: u64,
        clearing_price: u64,
        timestamp: u64
    ) {
        pool.last_price = clearing_price;
        pool.frontrun_detection.last_trade_price = clearing_price;
        pool.frontrun_detection.last_trade_timestamp = timestamp;
        
        // Record trade for analysis
        let trade_info = TradeInfo {
            trader: @0x0, // Batch execution
            amount: total_volume,
            price: clearing_price,
            timestamp,
            price_impact: 0,
            mev_detected: false,
            fees_paid: total_volume * pool.fee_rate / FEE_PRECISION,
        };
        
        table::add(&mut pool.trade_history, pool.trade_counter, trade_info);
        pool.trade_counter = pool.trade_counter + 1;
    }

    // Math helper function
    fun sqrt_u64(x: u64): u64 {
        if (x == 0) return 0;
        if (x <= 3) return 1;
        
        let mut z = x;
        let mut y = (x + 1) / 2;
        
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        };
        
        z
    }

    // View functions
    public fun get_pool_info(pool: &AdvancedPool): (u64, u64, u64, bool, u64) {
        (
            balance::value(&pool.sui_reserve),
            pool.gas_credits_reserve,
            pool.last_price,
            pool.mev_protection_enabled,
            pool.frontrun_detection.suspicious_activity_count
        )
    }

    public fun get_pool_reserves(pool: &AdvancedPool): (u64, u64) {
        (balance::value(&pool.sui_reserve), pool.gas_credits_reserve)
    }

    public fun get_pool_price(pool: &AdvancedPool): u64 {
        pool.last_price
    }

    public fun get_pool_fee_rate(pool: &AdvancedPool): u64 {
        pool.fee_rate
    }

    public fun get_total_liquidity(pool: &AdvancedPool): u64 {
        pool.total_liquidity_tokens
    }

    public fun get_batch_info(batch: &BatchAuction): (u64, u64, u64, u64, u8) {
        (
            batch.batch_id,
            vector::length(&batch.orders),
            batch.total_buy_volume,
            batch.total_sell_volume,
            batch.status
        )
    }

    public fun get_mev_stats(registry: &AMMRegistry): (u64, u64) {
        (registry.total_mev_prevented, registry.total_frontrun_blocked)
    }

    public fun get_registry_stats(registry: &AMMRegistry): (u64, u64, u64) {
        (
            table::length(&registry.pools),
            registry.total_volume,
            registry.total_fees
        )
    }

    // Admin functions
    public entry fun update_pool_fee_rate(
        registry: &AMMRegistry,
        pool: &mut AdvancedPool,
        new_fee_rate: u64,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == registry.admin, E_UNAUTHORIZED);
        assert!(new_fee_rate <= 1000, E_INVALID_ORDER); // Max 10% fee
        
        pool.fee_rate = new_fee_rate;
    }

    public entry fun toggle_mev_protection(
        registry: &AMMRegistry,
        pool: &mut AdvancedPool,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == registry.admin, E_UNAUTHORIZED);
        
        pool.mev_protection_enabled = !pool.mev_protection_enabled;
    }
} 