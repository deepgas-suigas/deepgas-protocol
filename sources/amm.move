/// Advanced AMM with MEV Protection for Gas Futures
/// Features batch auctions, MEV resistance, and sophisticated market making
module gas_futures::amm {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance, Supply};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::table::{Self, Table};
    use sui::transfer;
    use std::option::{Self, Option};
    use std::vector;
    
    // ORACLE INTEGRATION - Real oracle module
    use gas_futures::oracle::{Self, PriceOracle};

    // Error codes
    const E_UNAUTHORIZED: u64 = 0;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 1;
    const E_SLIPPAGE_TOO_HIGH: u64 = 2;
    const E_MEV_DETECTED: u64 = 3;
    const E_INVALID_ORDER: u64 = 4;
    const E_BATCH_NOT_READY: u64 = 5;
    const E_COMMITMENT_EXPIRED: u64 = 6;
    const E_INVALID_COMMITMENT: u64 = 7;
    const E_POOL_EXPIRED: u64 = 8;
    const E_FRONTRUN_DETECTED: u64 = 9;
    const E_ZERO_AMOUNT: u64 = 10;
    const E_INSUFFICIENT_LP_TOKENS: u64 = 11;
    const E_ORACLE_PRICE_DEVIATION: u64 = 12;
    const E_EMERGENCY_PAUSED: u64 = 13;

    // Constants - REALISTIC GAS ECONOMICS
    const BATCH_DURATION: u64 = 15000; // 15 seconds
    const MAX_SLIPPAGE: u64 = 1000; // 10%
    const MEV_THRESHOLD: u64 = 500; // FIXED: 5% price impact threshold (was 50%)
    const MIN_BATCH_SIZE: u64 = 3; // Minimum orders in batch
    const FEE_PRECISION: u64 = 10000; // 1 = 0.01%
    const PRICE_PRECISION: u64 = 1000000; // 1e6
    
    // REALISTIC GAS CREDITS MODEL
    // 1 SUI = 1,000,000,000 MIST
    // 1 Gas Credit = 1 MIST (actual gas consumption)
    // So 1 SUI = 1,000,000,000 Gas Credits in raw value
    const SUI_DECIMALS: u8 = 9;
    const SUI_MULTIPLIER: u64 = 1000000000; // 10^9
    const GAS_CREDITS_DECIMALS: u8 = 0; // No decimals, 1 credit = 1 MIST
    const MIST_PER_SUI: u64 = 1000000000;

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

    // Advanced liquidity pool with MEV protection - REAL GAS CREDITS
    public struct AdvancedPool has key {
        id: UID,
        duration_days: u64,
        sui_reserve: Balance<SUI>,
        gas_credits_reserve: Balance<GAS_CREDITS>, // REAL token balance
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
        // ADDED: Gas consumption tracking
        gas_consumed_total: u64,
        gas_price_oracle: ID,
        emergency_paused: bool,
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

    // ADDED: Gas Credits Token Type
    public struct GAS_CREDITS has drop {}

    // ADDED: Gas Credits Treasury for minting/burning
    public struct GasCreditsRegistry has key {
        id: UID,
        treasury_cap: TreasuryCap<GAS_CREDITS>,
        total_supply: u64,
        mint_authority: address,
        burn_authority: address,
        decimals: u8, // 9 decimals to match SUI
    }

    // ADDED: Access Control System
    public struct AdminCap has key, store {
        id: UID,
        admin: address,
        permissions: vector<u8>, // Bit flags for different permissions
        created_at: u64,
        last_used: u64,
    }

    // ADDED: Emergency Events
    public struct EmergencyPaused has copy, drop {
        pool_id: ID,
        reason: vector<u8>,
        admin: address,
        timestamp: u64,
    }

    public struct AdminActionExecuted has copy, drop {
        admin: address,
        action: vector<u8>,
        pool_id: Option<ID>,
        timestamp: u64,
        parameters: vector<u8>,
    }

    // ACCESS CONTROL PERMISSIONS
    const PERMISSION_PAUSE: u8 = 1;
    const PERMISSION_UNPAUSE: u8 = 2;
    const PERMISSION_UPDATE_FEES: u8 = 4;
    const PERMISSION_EMERGENCY_WITHDRAW: u8 = 8;
    const PERMISSION_UPDATE_ORACLE: u8 = 16;

    // ADDED: Gas Credits Events
    public struct GasCreditsIssued has copy, drop {
        amount: u64,
        recipient: address,
        total_supply: u64,
        timestamp: u64,
    }

    public struct GasCreditsBurned has copy, drop {
        amount: u64,
        burner: address,
        total_supply: u64,
        timestamp: u64,
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

    // Create advanced pool with MEV protection - REAL GAS CREDITS
    public entry fun create_advanced_pool(
        registry: &mut AMMRegistry,
        duration_days: u64,
        initial_sui: Coin<SUI>,
        initial_gas_credits: Coin<GAS_CREDITS>, // REAL gas credits coin
        enable_mev_protection: bool,
        oracle_id: ID, // Oracle reference
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sui_amount = coin::value(&initial_sui);
        let gas_credits_amount = coin::value(&initial_gas_credits);
        assert!(sui_amount > 0 && gas_credits_amount > 0, E_INSUFFICIENT_LIQUIDITY);

        let current_time = clock::timestamp_ms(clock);
        
        let initial_lp_tokens = sqrt_u64(sui_amount * gas_credits_amount);
        
        let pool = AdvancedPool {
            id: object::new(ctx),
            duration_days,
            sui_reserve: coin::into_balance(initial_sui),
            gas_credits_reserve: coin::into_balance(initial_gas_credits),
            total_liquidity_tokens: initial_lp_tokens,
            fee_rate: 30, // 0.3%
            last_price: (sui_amount * PRICE_PRECISION) / gas_credits_amount,
            price_impact_factor: 50, // 0.5%
            mev_protection_enabled: enable_mev_protection,
            frontrun_detection: FrontrunDetection {
                last_trade_price: (sui_amount * PRICE_PRECISION) / gas_credits_amount,
                last_trade_timestamp: current_time,
                large_order_threshold: sui_amount / 10,
                price_manipulation_threshold: 1000,
                suspicious_activity_count: 0,
            },
            batch_auction_id: option::none(),
            trade_history: table::new(ctx),
            trade_counter: 0,
            total_fees_collected: 0,
            created_at: current_time,
            gas_consumed_total: 0,
            gas_price_oracle: oracle_id,
            emergency_paused: false,
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

    // Main swap function - REAL GAS CREDITS VERSION - BUY ONLY
    public entry fun swap(
        pool: &mut AdvancedPool,
        payment: Coin<SUI>,
        is_buy: bool,
        min_output: u64,
        max_slippage: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!pool.emergency_paused, E_UNAUTHORIZED);
        assert!(is_buy, E_INVALID_ORDER); // This function only handles buying
        
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
        
        // FIXED: Proper min_output check
        assert!(amount_out >= min_output, E_SLIPPAGE_TOO_HIGH);
        
        // FIXED: Proper slippage calculation using price impact
        assert!(price_impact <= max_slippage, E_SLIPPAGE_TOO_HIGH);

        // Execute buy (SUI -> Gas Credits)
        let gas_reserve_value = balance::value(&pool.gas_credits_reserve);
        assert!(gas_reserve_value >= amount_out, E_INSUFFICIENT_LIQUIDITY);
        
        // Add SUI to pool
        balance::join(&mut pool.sui_reserve, coin::into_balance(payment));
        
        // Remove gas credits from pool and send to trader
        let gas_credits_out = balance::split(&mut pool.gas_credits_reserve, amount_out);
        let gas_credits_coin = coin::from_balance(gas_credits_out, ctx);
        transfer::public_transfer(gas_credits_coin, trader);

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
            is_buy: true,
            price: pool.last_price,
            price_impact,
            fees_paid: fee_amount,
        });
    }

    // FIXED: Dedicated sell function - PRODUCTION READY
    public entry fun sell_gas_credits(
        pool: &mut AdvancedPool,
        gas_credits_payment: Coin<GAS_CREDITS>,
        min_sui_output: u64,
        max_slippage: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!pool.emergency_paused, E_UNAUTHORIZED);
        
        let amount_in = coin::value(&gas_credits_payment);
        assert!(amount_in > 0, E_ZERO_AMOUNT);
        assert!(max_slippage <= MAX_SLIPPAGE, E_SLIPPAGE_TOO_HIGH);

        let current_time = clock::timestamp_ms(clock);
        let trader = tx_context::sender(ctx);

        // MEV Detection for selling
        if (pool.mev_protection_enabled && detect_mev(pool, amount_in, false, current_time)) {
            event::emit(MEVDetected {
                trader,
                transaction_hash: vector::empty(),
                price_impact: calculate_price_impact(pool, amount_in, false),
                blocked: true,
                timestamp: current_time,
            });
            abort E_MEV_DETECTED
        };

        // Calculate swap amounts for selling (is_buy = false)
        let (sui_amount_out, fee_amount, price_impact) = calculate_swap_amounts(pool, amount_in, false);
        
        // FIXED: Proper validation checks
        assert!(sui_amount_out >= min_sui_output, E_SLIPPAGE_TOO_HIGH);
        assert!(price_impact <= max_slippage, E_SLIPPAGE_TOO_HIGH);

        // Check SUI liquidity
        let sui_reserve_value = balance::value(&pool.sui_reserve);
        assert!(sui_reserve_value >= sui_amount_out, E_INSUFFICIENT_LIQUIDITY);

        // Execute sell (Gas Credits -> SUI)
        // 1. Take gas credits from user and add to pool
        balance::join(&mut pool.gas_credits_reserve, coin::into_balance(gas_credits_payment));
        
        // 2. Remove SUI from pool and give to trader
        let sui_out = balance::split(&mut pool.sui_reserve, sui_amount_out);
        transfer::public_transfer(coin::from_balance(sui_out, ctx), trader);

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
            amount_out: sui_amount_out,
            is_buy: false,
            price: pool.last_price,
            price_impact,
            fees_paid: fee_amount,
        });
    }

    // Add liquidity function - REAL GAS CREDITS VERSION
    public entry fun add_liquidity(
        pool: &mut AdvancedPool,
        sui_payment: Coin<SUI>,
        gas_credits_payment: Coin<GAS_CREDITS>, // Real gas credits coin
        min_lp_tokens: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!pool.emergency_paused, E_UNAUTHORIZED);
        
        let sui_amount = coin::value(&sui_payment);
        let gas_credits_amount = coin::value(&gas_credits_payment);
        assert!(sui_amount > 0 && gas_credits_amount > 0, E_ZERO_AMOUNT);

        let current_time = clock::timestamp_ms(clock);
        let provider = tx_context::sender(ctx);

        // Calculate LP tokens to mint
        let sui_reserve_value = balance::value(&pool.sui_reserve);
        let gas_reserve_value = balance::value(&pool.gas_credits_reserve);
        
        // FIXED: Balanced liquidity calculation - take average instead of minimum
        let lp_tokens_to_mint = if (pool.total_liquidity_tokens == 0) {
            sqrt_u64(sui_amount * gas_credits_amount)
        } else {
            let sui_ratio = (sui_amount * pool.total_liquidity_tokens) / sui_reserve_value;
            let gas_ratio = (gas_credits_amount * pool.total_liquidity_tokens) / gas_reserve_value;
            (sui_ratio + gas_ratio) / 2
        };

        assert!(lp_tokens_to_mint >= min_lp_tokens, E_SLIPPAGE_TOO_HIGH);

        // Add liquidity to pool
        balance::join(&mut pool.sui_reserve, coin::into_balance(sui_payment));
        balance::join(&mut pool.gas_credits_reserve, coin::into_balance(gas_credits_payment));
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

    // Remove liquidity function - REAL GAS CREDITS VERSION
    public entry fun remove_liquidity(
        pool: &mut AdvancedPool,
        lp_token: LPToken,
        min_sui: u64,
        min_gas_credits: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!pool.emergency_paused, E_UNAUTHORIZED);
        
        let current_time = clock::timestamp_ms(clock);
        let provider = tx_context::sender(ctx);
        
        // Verify LP token ownership
        assert!(lp_token.owner == provider, E_UNAUTHORIZED);
        assert!(lp_token.pool_id == object::uid_to_inner(&pool.id), E_INVALID_ORDER);

        let lp_amount = lp_token.amount;
        assert!(lp_amount > 0, E_INSUFFICIENT_LP_TOKENS);

        // Calculate withdrawal amounts
        let sui_reserve_value = balance::value(&pool.sui_reserve);
        let gas_reserve_value = balance::value(&pool.gas_credits_reserve);
        
        let sui_amount = (lp_amount * sui_reserve_value) / pool.total_liquidity_tokens;
        let gas_credits_amount = (lp_amount * gas_reserve_value) / pool.total_liquidity_tokens;

        assert!(sui_amount >= min_sui, E_SLIPPAGE_TOO_HIGH);
        assert!(gas_credits_amount >= min_gas_credits, E_SLIPPAGE_TOO_HIGH);

        // Remove liquidity from pool
        let sui_out = balance::split(&mut pool.sui_reserve, sui_amount);
        let gas_credits_out = balance::split(&mut pool.gas_credits_reserve, gas_credits_amount);
        pool.total_liquidity_tokens = pool.total_liquidity_tokens - lp_amount;

        // Transfer withdrawn amounts
        transfer::public_transfer(coin::from_balance(sui_out, ctx), provider);
        transfer::public_transfer(coin::from_balance(gas_credits_out, ctx), provider);

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

    // Calculate swap amounts - REALISTIC GAS ECONOMICS
    fun calculate_swap_amounts(
        pool: &AdvancedPool,
        amount_in: u64,
        is_buy: bool
    ): (u64, u64, u64) {
        let sui_reserve = balance::value(&pool.sui_reserve); // in MIST
        let gas_reserve = balance::value(&pool.gas_credits_reserve); // in MIST equivalents
        
        // Realistic gas economics:
        // SUI is in MIST (9 decimals), Gas Credits are raw MIST values
        
        if (is_buy) {
            // Buy gas credits with SUI (constant product formula: x * y = k)
            let amount_in_with_fee = amount_in * (FEE_PRECISION - pool.fee_rate) / FEE_PRECISION;
            let amount_out = (amount_in_with_fee * gas_reserve) / (sui_reserve + amount_in_with_fee);
            let fee_amount = amount_in - amount_in_with_fee;
            
            // Price impact as percentage (basis points)
            let price_impact = (amount_out * FEE_PRECISION) / gas_reserve;
            
            (amount_out, fee_amount, price_impact)
        } else {
            // Sell gas credits for SUI
            let amount_in_with_fee = amount_in * (FEE_PRECISION - pool.fee_rate) / FEE_PRECISION;
            let amount_out = (amount_in_with_fee * sui_reserve) / (gas_reserve + amount_in_with_fee);
            let fee_amount = amount_in - amount_in_with_fee;
            
            // Price impact as percentage (basis points)
            let price_impact = (amount_out * FEE_PRECISION) / sui_reserve;
            
            (amount_out, fee_amount, price_impact)
        }
    }

    // Calculate current price - FIXED HELPER FUNCTION
    fun calculate_current_price(pool: &AdvancedPool): u64 {
        let sui_reserve = balance::value(&pool.sui_reserve);
        
        // FIXED: Proper error handling and realistic price calculation
        if (balance::value(&pool.gas_credits_reserve) == 0) {
            // If no gas credits, price should be maximum (very expensive)
            return PRICE_PRECISION * 1000000 // Very high price when scarce
        };
        
        if (sui_reserve == 0) {
            return 0 // No SUI means no price reference
        };
        
        // FIXED: Correct price direction - gas credits per SUI unit
        (balance::value(&pool.gas_credits_reserve) * PRICE_PRECISION) / sui_reserve
    }

    // Calculate price impact for liquidity operations - FIXED DIVISION BY ZERO
    fun calculate_price_impact_liquidity(
        pool: &AdvancedPool,
        sui_amount: u64,
        gas_credits_amount: u64
    ): u64 {
        let sui_reserve = balance::value(&pool.sui_reserve);
        
        // FIXED: Prevent division by zero
        if (balance::value(&pool.gas_credits_reserve) == 0 || sui_reserve == 0) {
            return 0 // No price impact for empty pool
        };
        
        let current_ratio = (sui_reserve * PRICE_PRECISION) / balance::value(&pool.gas_credits_reserve);
        let new_ratio = ((sui_reserve + sui_amount) * PRICE_PRECISION) / (balance::value(&pool.gas_credits_reserve) + gas_credits_amount);
        
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
        assert!(batch_auction.status == AUCTION_ACCEPTING, E_INVALID_ORDER);
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
            (amount * FEE_PRECISION) / balance::value(&pool.gas_credits_reserve)
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
            balance::value(&pool.gas_credits_reserve),
            pool.last_price,
            pool.mev_protection_enabled,
            pool.frontrun_detection.suspicious_activity_count
        )
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

    // ADDED: Helper function for decimal conversions
    fun normalize_gas_credits(amount: u64): u64 {
        // Convert gas credits to 9 decimal format if needed
        amount * SUI_MULTIPLIER
    }
    
    // ADDED: Helper function to get human readable amounts
    fun get_human_readable_amount(amount: u64): u64 {
        amount / SUI_MULTIPLIER
    }

    // ADDED: Helper function for gas credits conversion
    fun gas_credits_to_mist(gas_credits: u64): u64 {
        // Since 1 gas credit = 1 MIST, direct conversion
        gas_credits
    }
    
    // ADDED: Helper function for MIST to gas credits
    fun mist_to_gas_credits(mist_amount: u64): u64 {
        // Since 1 MIST = 1 gas credit, direct conversion
        mist_amount
    }

    // Submit limit order - REALISTIC GAS ECONOMICS  
    public entry fun submit_limit_order(
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
        assert!(amount > 0, E_ZERO_AMOUNT);
        
        let current_time = clock::timestamp_ms(clock);
        let trader = tx_context::sender(ctx);

        // MEV and frontrun detection
        let mev_detected = detect_mev(pool, amount, is_buy, current_time);
        let frontrun_detected = detect_frontrun(pool, amount, current_time, ctx);
        
        assert!(!mev_detected, E_MEV_DETECTED);
        assert!(!frontrun_detected, E_FRONTRUN_DETECTED);

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

    // ORACLE INTEGRATION - Gas Price Detection
    // Oracle-based gas price validation using real oracle module
    public fun validate_gas_price_with_oracle(
        pool: &AdvancedPool,
        oracle: &PriceOracle,
        trade_amount: u64,
        clock: &Clock
    ): bool {
        // Get current gas price from oracle with confidence
        let (oracle_price, confidence, _timestamp) = oracle::get_price(oracle, clock);
        
        // Ensure oracle price is reliable (85% confidence minimum)
        if (confidence < 8500) {
            return false
        };
        
        let pool_price = calculate_current_price(pool);
        
        // Calculate price deviation from oracle
        let price_deviation = if (pool_price > oracle_price) {
            ((pool_price - oracle_price) * 10000) / oracle_price
        } else {
            ((oracle_price - pool_price) * 10000) / oracle_price
        };
        
        // Different thresholds for different trade sizes
        let max_deviation = if (trade_amount > pool.frontrun_detection.large_order_threshold) {
            200 // 2% for large orders - stricter
        } else {
            500 // 5% for normal orders
        };
        
        price_deviation <= max_deviation
    }

    // Oracle-integrated swap with price validation
    public entry fun oracle_validated_swap(
        pool: &mut AdvancedPool,
        oracle: &PriceOracle,
        payment: Coin<SUI>,
        is_buy: bool,
        min_output: u64,
        max_slippage: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!pool.emergency_paused, E_EMERGENCY_PAUSED);
        
        let amount_in = coin::value(&payment);
        
        // ORACLE PRICE VALIDATION - Critical for production safety
        assert!(validate_gas_price_with_oracle(pool, oracle, amount_in, clock), E_ORACLE_PRICE_DEVIATION);
        
        // Proceed with regular swap
        swap(pool, payment, is_buy, min_output, max_slippage, clock, ctx);
    }

    // Emergency circuit breaker using oracle anomaly detection
    public entry fun emergency_pause_if_anomaly(
        pool: &mut AdvancedPool,
        oracle: &PriceOracle,
        admin_cap: &mut AdminCap,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        // Get current pool price to compare with oracle
        let current_pool_price = calculate_current_price(pool);
        
        // Check for price anomalies comparing pool price to oracle
        let is_anomaly = oracle::is_price_anomaly(oracle, current_pool_price);
        
        if (is_anomaly) {
            pool.emergency_paused = true;
            admin_cap.last_used = clock::timestamp_ms(clock);
            
            event::emit(EmergencyPaused {
                pool_id: object::uid_to_inner(&pool.id),
                reason: b"Oracle price anomaly detected",
                admin: tx_context::sender(ctx),
                timestamp: clock::timestamp_ms(clock),
            });
        };
    }

    // Initialize admin capabilities
    public entry fun create_admin_cap(ctx: &mut TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx),
            admin: tx_context::sender(ctx),
            permissions: vector[255], // All permissions initially
            created_at: 0, // Will be set when used with clock
            last_used: 0,
        };
        
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    // Admin function to pause pool
    public entry fun admin_pause_pool(
        pool: &mut AdvancedPool,
        admin_cap: &mut AdminCap,
        reason: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        assert!(vector::contains(&admin_cap.permissions, &PERMISSION_PAUSE), E_UNAUTHORIZED);
        
        pool.emergency_paused = true;
        admin_cap.last_used = clock::timestamp_ms(clock);
        
        event::emit(EmergencyPaused {
            pool_id: object::uid_to_inner(&pool.id),
            reason,
            admin: tx_context::sender(ctx),
            timestamp: clock::timestamp_ms(clock),
        });
    }

    // Admin function to unpause pool
    public entry fun admin_unpause_pool(
        pool: &mut AdvancedPool,
        admin_cap: &mut AdminCap,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        assert!(vector::contains(&admin_cap.permissions, &PERMISSION_UNPAUSE), E_UNAUTHORIZED);
        
        pool.emergency_paused = false;
        admin_cap.last_used = clock::timestamp_ms(clock);
        
        event::emit(AdminActionExecuted {
            admin: tx_context::sender(ctx),
            action: b"unpause_pool",
            pool_id: option::some(object::uid_to_inner(&pool.id)),
            timestamp: clock::timestamp_ms(clock),
            parameters: vector::empty(),
        });
    }

    // Admin function to update fees
    public entry fun admin_update_fees(
        pool: &mut AdvancedPool,
        admin_cap: &mut AdminCap,
        new_fee_rate: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(admin_cap.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        assert!(vector::contains(&admin_cap.permissions, &PERMISSION_UPDATE_FEES), E_UNAUTHORIZED);
        assert!(new_fee_rate <= 500, E_INVALID_ORDER); // Max 5% fee
        
        let old_fee = pool.fee_rate;
        pool.fee_rate = new_fee_rate;
        admin_cap.last_used = clock::timestamp_ms(clock);
        
        event::emit(AdminActionExecuted {
            admin: tx_context::sender(ctx),
            action: b"update_fees",
            pool_id: option::some(object::uid_to_inner(&pool.id)),
            timestamp: clock::timestamp_ms(clock),
            parameters: vector[old_fee as u8, new_fee_rate as u8],
        });
    }

    // ENHANCED SLIPPAGE PROTECTION SYSTEM

    // Multi-layer slippage validation
    public fun validate_slippage_multi_layer(
        pool: &AdvancedPool,
        amount_in: u64,
        amount_out: u64,
        min_output: u64,
        max_slippage: u64,
        is_buy: bool
    ): bool {
        // Layer 1: Basic min output check
        if (amount_out < min_output) {
            return false
        };
        
        // Layer 2: Price impact calculation
        let price_impact = calculate_price_impact(pool, amount_in, is_buy);
        if (price_impact > max_slippage) {
            return false
        };
        
        // Layer 3: Liquidity depth check
        let sui_reserve = balance::value(&pool.sui_reserve);
        let gas_reserve = balance::value(&pool.gas_credits_reserve);
        
        if (is_buy) {
            // For buying gas credits, check gas reserve depth
            let impact_threshold = gas_reserve / 10; // Max 10% of reserve
            if (amount_out > impact_threshold) {
                return false
            };
        } else {
            // For selling gas credits, check SUI reserve depth
            let impact_threshold = sui_reserve / 10; // Max 10% of reserve
            if (amount_out > impact_threshold) {
                return false
            };
        };
        
        // Layer 4: Dynamic slippage based on volatility
        let dynamic_max_slippage = calculate_dynamic_slippage_limit(pool);
        if (price_impact > dynamic_max_slippage) {
            return false
        };
        
        true
    }

    // Calculate dynamic slippage limit based on recent volatility
    fun calculate_dynamic_slippage_limit(pool: &AdvancedPool): u64 {
        // Base slippage limit
        let base_limit = 500; // 5%
        
        // Check recent price movements
        let current_price = calculate_current_price(pool);
        let last_price = pool.frontrun_detection.last_trade_price;
        
        if (last_price == 0) {
            return base_limit
        };
        
        // Calculate recent price volatility
        let price_change = if (current_price > last_price) {
            ((current_price - last_price) * 10000) / last_price
        } else {
            ((last_price - current_price) * 10000) / last_price
        };
        
        // Increase slippage tolerance during high volatility
        if (price_change > 1000) { // If > 10% price change
            base_limit + 300 // Allow up to 8% slippage
        } else if (price_change > 500) { // If > 5% price change
            base_limit + 150 // Allow up to 6.5% slippage
        } else {
            base_limit // Normal 5% slippage
        }
    }

    // Enhanced swap with multi-layer slippage protection
    public entry fun protected_swap(
        pool: &mut AdvancedPool,
        payment: Coin<SUI>,
        is_buy: bool,
        min_output: u64,
        max_slippage: u64,
        deadline: u64, // Transaction deadline for MEV protection
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!pool.emergency_paused, E_EMERGENCY_PAUSED);
        
        // Check transaction deadline
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time <= deadline, E_POOL_EXPIRED);
        
        let amount_in = coin::value(&payment);
        assert!(amount_in > 0, E_ZERO_AMOUNT);

        // Calculate swap amounts
        let (amount_out, fee_amount, price_impact) = calculate_swap_amounts(pool, amount_in, is_buy);
        
        // ENHANCED MULTI-LAYER SLIPPAGE VALIDATION
        assert!(validate_slippage_multi_layer(
            pool, 
            amount_in, 
            amount_out, 
            min_output, 
            max_slippage, 
            is_buy
        ), E_SLIPPAGE_TOO_HIGH);

        // MEV Detection with enhanced protection
        if (pool.mev_protection_enabled && detect_mev(pool, amount_in, is_buy, current_time)) {
            event::emit(MEVDetected {
                trader: tx_context::sender(ctx),
                transaction_hash: vector::empty(),
                price_impact,
                blocked: true,
                timestamp: current_time,
            });
            abort E_MEV_DETECTED
        };

        // Execute swap with same logic as before
        let trader = tx_context::sender(ctx);
        
        if (is_buy) {
            let gas_reserve_value = balance::value(&pool.gas_credits_reserve);
            assert!(gas_reserve_value >= amount_out, E_INSUFFICIENT_LIQUIDITY);
            
            balance::join(&mut pool.sui_reserve, coin::into_balance(payment));
            let gas_credits_out = balance::split(&mut pool.gas_credits_reserve, amount_out);
            let gas_credits_coin = coin::from_balance(gas_credits_out, ctx);
            transfer::public_transfer(gas_credits_coin, trader);
            
        } else {
            let sui_reserve_value = balance::value(&pool.sui_reserve);
            assert!(sui_reserve_value >= amount_out, E_INSUFFICIENT_LIQUIDITY);
            
            let sui_out = balance::split(&mut pool.sui_reserve, amount_out);
            transfer::public_transfer(coin::from_balance(sui_out, ctx), trader);
            transfer::public_transfer(payment, trader);
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

    // Initialize Gas Credits Token System
    public entry fun init_gas_credits_token(ctx: &mut TxContext) {
        // Create treasury capability for GAS_CREDITS token
        let (treasury_cap, metadata) = coin::create_currency(
            GAS_CREDITS {},
            9, // 9 decimals to match SUI
            b"GAS",
            b"Gas Credits",
            b"SuiGas Platform Gas Credits - 1:1 backed by gas reserves",
            option::none(),
            ctx
        );

        let registry = GasCreditsRegistry {
            id: object::new(ctx),
            treasury_cap,
            total_supply: 0,
            mint_authority: tx_context::sender(ctx),
            burn_authority: tx_context::sender(ctx),
            decimals: 9,
        };

        // Share the metadata for public access
        transfer::public_freeze_object(metadata);
        // Share the registry
        transfer::share_object(registry);
    }

    // Mint gas credits (only for authorized contracts)
    public fun mint_gas_credits(
        registry: &mut GasCreditsRegistry,
        amount: u64, // Amount in 9-decimal format
        ctx: &mut TxContext
    ): Coin<GAS_CREDITS> {
        // Only mint authority or contract modules can mint
        assert!(
            tx_context::sender(ctx) == registry.mint_authority || 
            tx_context::sender(ctx) == @gas_futures, // Allow gas_futures module
            E_UNAUTHORIZED
        );

        let gas_credits = coin::mint(&mut registry.treasury_cap, amount, ctx);
        registry.total_supply = registry.total_supply + amount;

        event::emit(GasCreditsIssued {
            amount,
            recipient: tx_context::sender(ctx),
            total_supply: registry.total_supply,
            timestamp: 0, // Will be set by caller
        });

        gas_credits
    }

    // Burn gas credits
    public fun burn_gas_credits(
        registry: &mut GasCreditsRegistry,
        gas_credits: Coin<GAS_CREDITS>,
        ctx: &mut TxContext
    ) {
        let amount = coin::value(&gas_credits);
        coin::burn(&mut registry.treasury_cap, gas_credits);
        registry.total_supply = registry.total_supply - amount;

        event::emit(GasCreditsBurned {
            amount,
            burner: tx_context::sender(ctx),
            total_supply: registry.total_supply,
            timestamp: 0, // Will be set by caller
        });
    }

    // Convert u64 gas credits to Coin<GAS_CREDITS> (for integration)
    public fun u64_to_gas_credits_coin(
        registry: &mut GasCreditsRegistry,
        amount_u64: u64,
        ctx: &mut TxContext
    ): Coin<GAS_CREDITS> {
        // Convert raw gas credits (no decimals) to 9-decimal format
        let amount_with_decimals = amount_u64 * 1000000000; // 10^9
        mint_gas_credits(registry, amount_with_decimals, ctx)
    }

    // Convert Coin<GAS_CREDITS> to u64 (for legacy compatibility)
    public fun gas_credits_coin_to_u64(gas_credits: &Coin<GAS_CREDITS>): u64 {
        // Convert 9-decimal format back to raw gas credits
        coin::value(gas_credits) / 1000000000 // 10^9
    }

    // Utility: Convert MIST to GAS_CREDITS coin format
    public fun mist_to_gas_credits_coin(
        registry: &mut GasCreditsRegistry,
        mist_amount: u64,
        ctx: &mut TxContext
    ): Coin<GAS_CREDITS> {
        // 1 MIST = 1 Gas Credit in value, but we use 9 decimals
        // So 1 MIST = 1,000,000,000 atomic Gas Credits units
        mint_gas_credits(registry, mist_amount, ctx)
    }

    // UTILITY: Get swap preview without executing
    public fun get_swap_preview(
        pool: &AdvancedPool,
        amount_in: u64,
        is_buy: bool
    ): (u64, u64, u64) {
        calculate_swap_amounts(pool, amount_in, is_buy)
    }

    // UTILITY: Check if swap is profitable
    public fun is_swap_profitable(
        pool: &AdvancedPool,
        amount_in: u64,
        is_buy: bool,
        min_profit_bps: u64
    ): bool {
        let (amount_out, fee_amount, price_impact) = calculate_swap_amounts(pool, amount_in, is_buy);
        
        // Calculate net gain after fees
        let net_out = if (amount_out > fee_amount) {
            amount_out - fee_amount
        } else {
            0
        };
        
        // Check if net gain meets minimum profit threshold
        if (amount_in == 0) return false;
        let profit_bps = ((net_out * 10000) / amount_in);
        profit_bps >= (10000 + min_profit_bps) // Must exceed input + min profit
    }

    // UTILITY: Get pool trading statistics
    public fun get_pool_stats(pool: &AdvancedPool): (u64, u64, u64, u64) {
        (
            pool.last_price,
            pool.total_fees_collected,
            pool.trade_counter,
            pool.total_liquidity_tokens
        )
    }
} 