/// Yield Farming for Gas Credits
/// Allows users to stake gas credits and earn rewards through DeFi mechanisms
module gas_futures::yield_farming {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::table::{Self, Table};
    use sui::transfer;
    use std::string::{Self, String};
    use std::vector;

    // Error codes
    const E_INSUFFICIENT_STAKE: u64 = 1;
    const E_POOL_NOT_FOUND: u64 = 2;
    const E_UNAUTHORIZED: u64 = 3;
    const E_FARMING_PERIOD_ENDED: u64 = 4;
    const E_INSUFFICIENT_REWARDS: u64 = 5;
    const E_EARLY_WITHDRAWAL: u64 = 6;
    const E_INVALID_MULTIPLIER: u64 = 7;

    // Farming pool durations (in milliseconds)
    const FARMING_DURATION_7_DAYS: u64 = 604800000;  // 7 days
    const FARMING_DURATION_30_DAYS: u64 = 2592000000; // 30 days
    const FARMING_DURATION_90_DAYS: u64 = 7776000000; // 90 days

    // Reward multipliers (basis points)
    const MULTIPLIER_7_DAYS: u64 = 500;   // 5% APY
    const MULTIPLIER_30_DAYS: u64 = 1200;  // 12% APY
    const MULTIPLIER_90_DAYS: u64 = 2500;  // 25% APY

    // Bonus multipliers for volume
    const VOLUME_BONUS_BRONZE: u64 = 100;   // 1%
    const VOLUME_BONUS_SILVER: u64 = 250;   // 2.5%
    const VOLUME_BONUS_GOLD: u64 = 500;     // 5%

    // Gas yield farming pool
    public struct GasYieldPool has key {
        id: UID,
        pool_name: String,
        staked_gas_credits: u64,
        total_participants: u64,
        reward_rate: u64, // APY in basis points
        farming_duration: u64,
        pool_start_time: u64,
        pool_end_time: u64,
        participants: Table<address, StakeInfo>,
        reward_balance: Balance<SUI>,
        emergency_withdrawal_enabled: bool,
        pool_admin: address,
        total_rewards_distributed: u64,
        compounding_enabled: bool,
    }

    // Individual stake information
    public struct StakeInfo has store, drop {
        staked_amount: u64,
        stake_timestamp: u64,
        last_reward_calculation: u64,
        pending_rewards: u64,
        volume_bonus_tier: u8,
        lock_end_time: u64,
        auto_compound: bool,
        total_rewards_earned: u64,
    }

    // Yield farming registry
    public struct YieldFarmingRegistry has key {
        id: UID,
        active_pools: Table<u64, ID>, // pool_id -> pool_object_id
        pool_counter: u64,
        total_staked_across_pools: u64,
        total_rewards_distributed: u64,
        governance_fee_rate: u64, // Fee for protocol treasury
        admin: address,
    }

    // Liquidity mining rewards
    public struct LiquidityMiningReward has key, store {
        id: UID,
        pool_id: u64,
        recipient: address,
        reward_amount: u64,
        earned_timestamp: u64,
        reward_type: u8, // 1: staking, 2: trading volume, 3: referral
        claimed: bool,
    }

    // Compound farming strategy
    public struct CompoundStrategy has key {
        id: UID,
        strategy_name: String,
        pools: vector<u64>, // Pool IDs included in strategy
        pool_weights: vector<u64>, // Corresponding weights for pools
        rebalance_frequency: u64,
        last_rebalance: u64,
        total_managed_amount: u64,
        performance_fee: u64,
        strategy_manager: address,
    }

    // Cross-chain yield opportunity
    public struct CrossChainYield has key {
        id: UID,
        target_chain: String,
        protocol_name: String,
        estimated_apy: u64,
        risk_level: u8, // 1: low, 2: medium, 3: high
        required_bridge_fee: u64,
        minimum_deposit: u64,
        active: bool,
    }

    // Events
    public struct PoolCreated has copy, drop {
        pool_id: ID,
        pool_name: String,
        reward_rate: u64,
        farming_duration: u64,
        admin: address,
    }

    public struct GasStaked has copy, drop {
        pool_id: ID,
        user: address,
        amount: u64,
        lock_end_time: u64,
        expected_rewards: u64,
    }

    public struct RewardsClaimed has copy, drop {
        pool_id: ID,
        user: address,
        reward_amount: u64,
        auto_compounded: bool,
        timestamp: u64,
    }

    public struct EmergencyWithdrawal has copy, drop {
        pool_id: ID,
        user: address,
        amount: u64,
        penalty_applied: u64,
        timestamp: u64,
    }

    public struct StrategyCreated has copy, drop {
        strategy_id: ID,
        strategy_name: String,
        pools_count: u64,
        manager: address,
        performance_fee: u64,
    }

    public struct CrossChainBridged has copy, drop {
        user: address,
        amount: u64,
        target_chain: vector<u8>,
        bridge_fee: u64,
        estimated_yield: u64,
    }

    public struct RewardMinted has copy, drop {
        recipient: address,
        pool_id: u64,
        reward_amount: u64,
        reward_type: u8,
        timestamp: u64,
    }

    // Initialize yield farming system
    fun init(ctx: &mut TxContext) {
        let registry = YieldFarmingRegistry {
            id: object::new(ctx),
            active_pools: table::new(ctx),
            pool_counter: 0,
            total_staked_across_pools: 0,
            total_rewards_distributed: 0,
            governance_fee_rate: 1000, // 10% fee
            admin: tx_context::sender(ctx),
        };
        transfer::share_object(registry)
    }

    // Create new yield farming pool
    public entry fun create_yield_pool(
        registry: &mut YieldFarmingRegistry,
        pool_name: vector<u8>,
        reward_rate: u64,
        farming_duration: u64,
        initial_rewards: Coin<SUI>,
        enable_compounding: bool,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(registry.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        let current_time = clock::timestamp_ms(clock);
        let pool_id = registry.pool_counter;
        registry.pool_counter = registry.pool_counter + 1;

        let pool = GasYieldPool {
            id: object::new(ctx),
            pool_name: string::utf8(pool_name),
            staked_gas_credits: 0,
            total_participants: 0,
            reward_rate,
            farming_duration,
            pool_start_time: current_time,
            pool_end_time: current_time + farming_duration,
            participants: table::new(ctx),
            reward_balance: coin::into_balance(initial_rewards),
            emergency_withdrawal_enabled: false,
            pool_admin: tx_context::sender(ctx),
            total_rewards_distributed: 0,
            compounding_enabled: enable_compounding,
        };

        let pool_object_id = object::uid_to_inner(&pool.id);
        table::add(&mut registry.active_pools, pool_id, pool_object_id);

        event::emit(PoolCreated {
            pool_id: pool_object_id,
            pool_name: pool.pool_name,
            reward_rate,
            farming_duration,
            admin: tx_context::sender(ctx),
        });

        transfer::share_object(pool)
    }

    // Stake gas credits in yield farming pool
    public entry fun stake_gas_credits(
        registry: &mut YieldFarmingRegistry,
        pool: &mut GasYieldPool,
        stake_amount: u64,
        auto_compound: bool,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time < pool.pool_end_time, E_FARMING_PERIOD_ENDED);
        assert!(stake_amount > 0, E_INSUFFICIENT_STAKE);

        let user = tx_context::sender(ctx);
        let lock_end_time = current_time + pool.farming_duration;

        // Calculate volume bonus tier (simplified)
        let volume_bonus_tier = calculate_volume_tier(registry, user);

        if (table::contains(&pool.participants, user)) {
            // Update existing stake
            let stake_info = table::borrow_mut(&mut pool.participants, user);
            stake_info.staked_amount = stake_info.staked_amount + stake_amount;
            stake_info.volume_bonus_tier = volume_bonus_tier;
            stake_info.auto_compound = auto_compound;
        } else {
            // Create new stake
            let stake_info = StakeInfo {
                staked_amount: stake_amount,
                stake_timestamp: current_time,
                last_reward_calculation: current_time,
                pending_rewards: 0,
                volume_bonus_tier,
                lock_end_time,
                auto_compound,
                total_rewards_earned: 0,
            };
            table::add(&mut pool.participants, user, stake_info);
            pool.total_participants = pool.total_participants + 1;
        };

        pool.staked_gas_credits = pool.staked_gas_credits + stake_amount;
        registry.total_staked_across_pools = registry.total_staked_across_pools + stake_amount;

        // Calculate expected rewards
        let expected_rewards = calculate_expected_rewards(
            stake_amount,
            pool.reward_rate,
            pool.farming_duration,
            volume_bonus_tier
        );

        event::emit(GasStaked {
            pool_id: object::uid_to_inner(&pool.id),
            user,
            amount: stake_amount,
            lock_end_time,
            expected_rewards,
        });
    }

    // Claim farming rewards
    public entry fun claim_rewards(
        registry: &mut YieldFarmingRegistry,
        pool: &mut GasYieldPool,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let user = tx_context::sender(ctx);
        
        assert!(table::contains(&pool.participants, user), E_INSUFFICIENT_STAKE);
        
        // Calculate accumulated rewards first with immutable borrow
        let rewards = {
            let stake_info = table::borrow(&pool.participants, user);
            calculate_accumulated_rewards(stake_info, pool, current_time)
        };
        assert!(rewards > 0, E_INSUFFICIENT_REWARDS);
        assert!(balance::value(&pool.reward_balance) >= rewards, E_INSUFFICIENT_REWARDS);

        // Update stake info with mutable borrow
        let stake_info = table::borrow_mut(&mut pool.participants, user);
        stake_info.pending_rewards = 0;
        stake_info.last_reward_calculation = current_time;
        stake_info.total_rewards_earned = stake_info.total_rewards_earned + rewards;

        // Apply governance fee
        let governance_fee = (rewards * registry.governance_fee_rate) / 10000;
        let net_rewards = rewards - governance_fee;

        if (stake_info.auto_compound && pool.compounding_enabled) {
            // Auto-compound: add rewards to staked amount
            stake_info.staked_amount = stake_info.staked_amount + net_rewards;
            pool.staked_gas_credits = pool.staked_gas_credits + net_rewards;
            
            event::emit(RewardsClaimed {
                pool_id: object::uid_to_inner(&pool.id),
                user,
                reward_amount: net_rewards,
                auto_compounded: true,
                timestamp: current_time,
            });
        } else {
            // Transfer rewards to user
            let reward_coin = coin::take(&mut pool.reward_balance, net_rewards, ctx);
            transfer::public_transfer(reward_coin, user);
            
            event::emit(RewardsClaimed {
                pool_id: object::uid_to_inner(&pool.id),
                user,
                reward_amount: net_rewards,
                auto_compounded: false,
                timestamp: current_time,
            });
        };

        pool.total_rewards_distributed = pool.total_rewards_distributed + rewards;
        registry.total_rewards_distributed = registry.total_rewards_distributed + rewards;
    }

    // Emergency withdrawal (with penalty)
    public entry fun emergency_withdraw(
        pool: &mut GasYieldPool,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(pool.emergency_withdrawal_enabled, E_UNAUTHORIZED);
        
        let current_time = clock::timestamp_ms(clock);
        let user = tx_context::sender(ctx);
        
        assert!(table::contains(&pool.participants, user), E_INSUFFICIENT_STAKE);
        
        let stake_info = table::remove(&mut pool.participants, user);
        
        // Calculate early withdrawal penalty (20%)
        let penalty_rate = 2000; // 20%
        let penalty_amount = (stake_info.staked_amount * penalty_rate) / 10000;
        let withdrawal_amount = stake_info.staked_amount - penalty_amount;

        pool.staked_gas_credits = pool.staked_gas_credits - stake_info.staked_amount;
        pool.total_participants = pool.total_participants - 1;

        event::emit(EmergencyWithdrawal {
            pool_id: object::uid_to_inner(&pool.id),
            user,
            amount: withdrawal_amount,
            penalty_applied: penalty_amount,
            timestamp: current_time,
        });

        // Note: In production, would transfer actual gas credits back to user
        // For now, just emit event
    }

    // Create compound farming strategy
    public entry fun create_compound_strategy(
        strategy_name: vector<u8>,
        pools: vector<u64>,
        pool_weights: vector<u64>,
        rebalance_frequency: u64,
        performance_fee: u64,
        ctx: &mut TxContext
    ) {
        assert!(vector::length(&pools) == vector::length(&pool_weights), E_INVALID_MULTIPLIER);
        
        let strategy = CompoundStrategy {
            id: object::new(ctx),
            strategy_name: string::utf8(strategy_name),
            pools,
            pool_weights,
            rebalance_frequency,
            last_rebalance: 0,
            total_managed_amount: 0,
            performance_fee,
            strategy_manager: tx_context::sender(ctx),
        };

        event::emit(StrategyCreated {
            strategy_id: object::uid_to_inner(&strategy.id),
            strategy_name: strategy.strategy_name,
            pools_count: vector::length(&pools),
            manager: tx_context::sender(ctx),
            performance_fee,
        });

        transfer::transfer(strategy, tx_context::sender(ctx));
    }

    // Create liquidity mining reward
    public entry fun create_liquidity_reward(
        pool_id: u64,
        recipient: address,
        reward_amount: u64,
        reward_type: u8,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        
        let reward = LiquidityMiningReward {
            id: object::new(ctx),
            pool_id,
            recipient,
            reward_amount,
            earned_timestamp: current_time,
            reward_type,
            claimed: false,
        };

        event::emit(RewardMinted {
            recipient,
            pool_id,
            reward_amount,
            reward_type,
            timestamp: current_time,
        });

        transfer::transfer(reward, recipient);
    }

    // Create cross-chain yield opportunity
    public entry fun create_cross_chain_yield(
        target_chain: vector<u8>,
        protocol_name: vector<u8>,
        estimated_apy: u64,
        risk_level: u8,
        required_bridge_fee: u64,
        minimum_deposit: u64,
        ctx: &mut TxContext
    ) {
        let yield_opportunity = CrossChainYield {
            id: object::new(ctx),
            target_chain: string::utf8(target_chain),
            protocol_name: string::utf8(protocol_name),
            estimated_apy,
            risk_level,
            required_bridge_fee,
            minimum_deposit,
            active: true,
        };

        transfer::transfer(yield_opportunity, tx_context::sender(ctx));
    }

    // Bridge to cross-chain yield
    public entry fun bridge_to_cross_chain(
        yield_opportunity: &CrossChainYield,
        amount: u64,
        bridge_payment: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(yield_opportunity.active, E_UNAUTHORIZED);
        assert!(amount >= yield_opportunity.minimum_deposit, E_INSUFFICIENT_STAKE);
        assert!(coin::value(&bridge_payment) >= yield_opportunity.required_bridge_fee, E_INSUFFICIENT_REWARDS);

        let current_time = clock::timestamp_ms(clock);

        // Process bridge fee payment
        transfer::public_transfer(bridge_payment, @0x0); // Bridge treasury

        event::emit(CrossChainBridged {
            user: tx_context::sender(ctx),
            amount,
            target_chain: *string::bytes(&yield_opportunity.target_chain),
            bridge_fee: yield_opportunity.required_bridge_fee,
            estimated_yield: (amount * yield_opportunity.estimated_apy) / 10000,
        });
    }

    // Helper functions
    fun calculate_volume_tier(_registry: &YieldFarmingRegistry, _user: address): u8 {
        // Simplified volume tier calculation
        // In production, would check user's trading history
        let user_volume = 1000000; // Placeholder
        
        if (user_volume >= 10000000) {
            3 // Gold tier
        } else if (user_volume >= 5000000) {
            2 // Silver tier
        } else if (user_volume >= 1000000) {
            1 // Bronze tier
        } else {
            0 // No tier
        }
    }

    fun calculate_expected_rewards(
        stake_amount: u64,
        reward_rate: u64,
        farming_duration: u64,
        volume_bonus_tier: u8
    ): u64 {
        let base_rewards = (stake_amount * reward_rate * farming_duration) / (365 * 24 * 60 * 60 * 1000 * 10000);
        
        let volume_bonus = if (volume_bonus_tier == 3) {
            VOLUME_BONUS_GOLD
        } else if (volume_bonus_tier == 2) {
            VOLUME_BONUS_SILVER
        } else if (volume_bonus_tier == 1) {
            VOLUME_BONUS_BRONZE
        } else {
            0
        };
        
        let bonus_amount = (base_rewards * volume_bonus) / 10000;
        base_rewards + bonus_amount
    }

    fun calculate_accumulated_rewards(
        stake_info: &StakeInfo,
        pool: &GasYieldPool,
        current_time: u64
    ): u64 {
        let time_staked = current_time - stake_info.last_reward_calculation;
        let rewards = (stake_info.staked_amount * pool.reward_rate * time_staked) / 
                     (365 * 24 * 60 * 60 * 1000 * 10000);
        
        // Apply volume bonus
        let volume_bonus = if (stake_info.volume_bonus_tier == 3) {
            VOLUME_BONUS_GOLD
        } else if (stake_info.volume_bonus_tier == 2) {
            VOLUME_BONUS_SILVER
        } else if (stake_info.volume_bonus_tier == 1) {
            VOLUME_BONUS_BRONZE
        } else {
            0
        };
        
        let bonus_amount = (rewards * volume_bonus) / 10000;
        rewards + bonus_amount + stake_info.pending_rewards
    }

    // View functions
    public fun get_pool_info(pool: &GasYieldPool): (String, u64, u64, u64, u64, u64, bool) {
        (
            pool.pool_name,
            pool.staked_gas_credits,
            pool.total_participants,
            pool.reward_rate,
            pool.pool_start_time,
            pool.pool_end_time,
            pool.compounding_enabled
        )
    }

    public fun get_stake_info(pool: &GasYieldPool, user: address): (u64, u64, u64, u64, u8, bool) {
        if (table::contains(&pool.participants, user)) {
            let stake_info = table::borrow(&pool.participants, user);
            (
                stake_info.staked_amount,
                stake_info.stake_timestamp,
                stake_info.pending_rewards,
                stake_info.lock_end_time,
                stake_info.volume_bonus_tier,
                stake_info.auto_compound
            )
        } else {
            (0, 0, 0, 0, 0, false)
        }
    }

    public fun get_farming_stats(registry: &YieldFarmingRegistry): (u64, u64, u64) {
        (
            registry.pool_counter,
            registry.total_staked_across_pools,
            registry.total_rewards_distributed
        )
    }

    public fun get_strategy_info(strategy: &CompoundStrategy): (String, vector<u64>, vector<u64>, u64, address) {
        (
            strategy.strategy_name,
            strategy.pools,
            strategy.pool_weights,
            strategy.performance_fee,
            strategy.strategy_manager
        )
    }

    public fun get_cross_chain_info(yield_opp: &CrossChainYield): (String, String, u64, u8, u64, bool) {
        (
            yield_opp.target_chain,
            yield_opp.protocol_name,
            yield_opp.estimated_apy,
            yield_opp.risk_level,
            yield_opp.minimum_deposit,
            yield_opp.active
        )
    }

    public fun calculate_current_apy(pool: &GasYieldPool, volume_tier: u8): u64 {
        let base_apy = pool.reward_rate;
        let volume_bonus = if (volume_tier == 3) {
            VOLUME_BONUS_GOLD
        } else if (volume_tier == 2) {
            VOLUME_BONUS_SILVER
        } else if (volume_tier == 1) {
            VOLUME_BONUS_BRONZE
        } else {
            0
        };
        
        base_apy + volume_bonus
    }

    // Withdraw staked tokens after farming period ends
    public entry fun withdraw_stake(
        registry: &mut YieldFarmingRegistry,
        pool: &mut GasYieldPool,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let user = tx_context::sender(ctx);
        
        assert!(table::contains(&pool.participants, user), E_INSUFFICIENT_STAKE);
        
        let stake_info = table::borrow(&pool.participants, user);
        assert!(current_time >= stake_info.lock_end_time, E_EARLY_WITHDRAWAL);
        
        // Claim any pending rewards first
        claim_rewards(registry, pool, clock, ctx);
        
        // Remove stake
        let final_stake_info = table::remove(&mut pool.participants, user);
        pool.staked_gas_credits = pool.staked_gas_credits - final_stake_info.staked_amount;
        pool.total_participants = pool.total_participants - 1;
        registry.total_staked_across_pools = registry.total_staked_across_pools - final_stake_info.staked_amount;

        // In production, would transfer actual gas credits back to user
        // For now, just emit event with withdrawal amount
        event::emit(RewardsClaimed {
            pool_id: object::uid_to_inner(&pool.id),
            user,
            reward_amount: final_stake_info.staked_amount,
            auto_compounded: false,
            timestamp: current_time,
        });
    }

    // Update pool reward rate (admin only)
    public entry fun update_pool_reward_rate(
        pool: &mut GasYieldPool,
        new_rate: u64,
        ctx: &mut TxContext
    ) {
        assert!(pool.pool_admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        pool.reward_rate = new_rate;
    }

    // Add rewards to pool
    public entry fun add_pool_rewards(
        pool: &mut GasYieldPool,
        additional_rewards: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        assert!(pool.pool_admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        balance::join(&mut pool.reward_balance, coin::into_balance(additional_rewards));
    }

    // Enable/disable emergency withdrawals
    public entry fun toggle_emergency_withdrawal(
        pool: &mut GasYieldPool,
        enabled: bool,
        ctx: &mut TxContext
    ) {
        assert!(pool.pool_admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        pool.emergency_withdrawal_enabled = enabled;
    }

    // Rebalance compound strategy
    public entry fun rebalance_strategy(
        strategy: &mut CompoundStrategy,
        new_pool_weights: vector<u64>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(strategy.strategy_manager == tx_context::sender(ctx), E_UNAUTHORIZED);
        assert!(vector::length(&new_pool_weights) == vector::length(&strategy.pools), E_INVALID_MULTIPLIER);
        
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time >= strategy.last_rebalance + strategy.rebalance_frequency, E_EARLY_WITHDRAWAL);
        
        strategy.pool_weights = new_pool_weights;
        strategy.last_rebalance = current_time;
    }

    // Claim liquidity mining reward
    public entry fun claim_liquidity_reward(
        reward: &mut LiquidityMiningReward,
        ctx: &mut TxContext
    ) {
        assert!(reward.recipient == tx_context::sender(ctx), E_UNAUTHORIZED);
        assert!(!reward.claimed, E_UNAUTHORIZED);
        
        reward.claimed = true;
        
        // In production, would mint/transfer actual reward tokens
        event::emit(RewardsClaimed {
            pool_id: object::uid_to_inner(&reward.id),
            user: reward.recipient,
            reward_amount: reward.reward_amount,
            auto_compounded: false,
            timestamp: reward.earned_timestamp,
        });
    }

    // Update cross-chain yield status
    public entry fun update_cross_chain_yield(
        yield_opp: &mut CrossChainYield,
        new_apy: u64,
        new_risk_level: u8,
        active: bool,
        ctx: &mut TxContext
    ) {
        yield_opp.estimated_apy = new_apy;
        yield_opp.risk_level = new_risk_level;
        yield_opp.active = active;
    }

    // Calculate total pool value (TVL)
    public fun calculate_pool_tvl(pool: &GasYieldPool): u64 {
        pool.staked_gas_credits + balance::value(&pool.reward_balance)
    }

    // Get pool performance metrics
    public fun get_pool_performance(pool: &GasYieldPool, current_time: u64): (u64, u64, u64) {
        let pool_age = current_time - pool.pool_start_time;
        let avg_daily_rewards = if (pool_age > 0) {
            (pool.total_rewards_distributed * 86400000) / pool_age // Daily average
        } else {
            0
        };
        
        let utilization_rate = if (balance::value(&pool.reward_balance) > 0) {
            (pool.total_rewards_distributed * 10000) / 
            (pool.total_rewards_distributed + balance::value(&pool.reward_balance))
        } else {
            10000 // 100% if no rewards left
        };

        (
            calculate_pool_tvl(pool),
            avg_daily_rewards,
            utilization_rate
        )
    }

    // Mass update all user rewards in pool
    public entry fun mass_update_rewards(
        pool: &mut GasYieldPool,
        user_addresses: vector<address>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(pool.pool_admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        let current_time = clock::timestamp_ms(clock);
        let mut i = 0;
        let users_count = vector::length(&user_addresses);
        
        while (i < users_count) {
            let user_addr = *vector::borrow(&user_addresses, i);
            if (table::contains(&pool.participants, user_addr)) {
                // First calculate rewards with immutable borrows
                let accumulated = {
                    let stake_info = table::borrow(&pool.participants, user_addr);
                    calculate_accumulated_rewards(stake_info, pool, current_time)
                };
                // Then update with mutable borrow
                let stake_info = table::borrow_mut(&mut pool.participants, user_addr);
                stake_info.pending_rewards = accumulated;
                stake_info.last_reward_calculation = current_time;
            };
            i = i + 1;
        };
    }

    // Extend pool duration
    public entry fun extend_pool_duration(
        pool: &mut GasYieldPool,
        additional_duration: u64,
        additional_rewards: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        assert!(pool.pool_admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        pool.pool_end_time = pool.pool_end_time + additional_duration;
        balance::join(&mut pool.reward_balance, coin::into_balance(additional_rewards));
    }

    // Calculate impermanent loss protection
    public fun calculate_impermanent_loss_protection(
        initial_stake: u64,
        current_stake_value: u64,
        rewards_earned: u64
    ): u64 {
        if (current_stake_value >= initial_stake) {
            0 // No loss
        } else {
            let loss = initial_stake - current_stake_value;
            if (rewards_earned >= loss) {
                0 // Rewards cover the loss
            } else {
                loss - rewards_earned // Remaining loss
            }
        }
    }

    // Calculate simple APY for a pool
    public fun calculate_simple_apy(
        pool: &GasYieldPool,
        volume_tier: u8
    ): u64 {
        let base_apy = pool.reward_rate;
        let volume_bonus = if (volume_tier == 3) {
            VOLUME_BONUS_GOLD
        } else if (volume_tier == 2) {
            VOLUME_BONUS_SILVER
        } else if (volume_tier == 1) {
            VOLUME_BONUS_BRONZE
        } else {
            0
        };
        
        base_apy + volume_bonus
    }

    // Calculate yield for specific allocation
    public fun calculate_allocation_yield(
        total_amount: u64,
        allocation_percentage: u64, // in basis points (100 = 1%)
        pool_apy: u64
    ): u64 {
        let allocated_amount = (total_amount * allocation_percentage) / 10000;
        (allocated_amount * pool_apy) / 10000
    }

    // Get comprehensive farming analytics
    public fun get_farming_analytics(
        pool: &GasYieldPool,
        user: address,
        current_time: u64
    ): (u64, u64, u64, u64, u64) {
        if (!table::contains(&pool.participants, user)) {
            return (0, 0, 0, 0, 0)
        };
        
        let stake_info = table::borrow(&pool.participants, user);
        let pending_rewards = calculate_accumulated_rewards(stake_info, pool, current_time);
        let time_remaining = if (current_time < stake_info.lock_end_time) {
            stake_info.lock_end_time - current_time
        } else {
            0
        };
        
        let current_apy = calculate_current_apy(pool, stake_info.volume_bonus_tier);
        let projected_total_rewards = calculate_expected_rewards(
            stake_info.staked_amount,
            current_apy,
            time_remaining,
            stake_info.volume_bonus_tier
        );
        
        (
            stake_info.staked_amount,
            pending_rewards,
            time_remaining,
            current_apy,
            projected_total_rewards
        )
    }
} 