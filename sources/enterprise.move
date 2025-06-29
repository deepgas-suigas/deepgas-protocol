/// Enterprise Gas Management for Institutional Clients
/// Provides corporate accounts, volume discounts, and dedicated gas pools
module gas_futures::enterprise {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::table::{Self, Table};
    use std::string::{Self, String};

    // Error codes
    const E_UNAUTHORIZED: u64 = 1;
    const E_INSUFFICIENT_BUDGET: u64 = 2;
    const E_ACCOUNT_NOT_FOUND: u64 = 3;
    const E_INVALID_DISCOUNT_TIER: u64 = 4;
    const E_BUDGET_EXCEEDED: u64 = 5;
    const E_INVALID_ALLOCATION: u64 = 6;

    // Volume discount tiers
    const TIER_BRONZE: u64 = 1000000;    // 1M gas credits
    const TIER_SILVER: u64 = 5000000;    // 5M gas credits
    const TIER_GOLD: u64 = 20000000;     // 20M gas credits
    const TIER_PLATINUM: u64 = 100000000; // 100M gas credits

    // Discount rates (basis points)
    const DISCOUNT_BRONZE: u64 = 500;    // 5%
    const DISCOUNT_SILVER: u64 = 1000;   // 10%
    const DISCOUNT_GOLD: u64 = 1500;     // 15%
    const DISCOUNT_PLATINUM: u64 = 2000; // 20%

    // Corporate account for enterprise clients
    public struct CorporateAccount has key, store {
        id: UID,
        company_name: String,
        admin: address,
        authorized_users: Table<address, bool>,
        monthly_gas_budget: u64,
        current_month_usage: u64,
        total_lifetime_usage: u64,
        auto_renewal: bool,
        discount_tier: u8,
        dedicated_validator_pool: Option<address>,
        created_at: u64,
        last_budget_reset: u64,
    }

    // Enterprise registry
    public struct EnterpriseRegistry has key {
        id: UID,
        corporate_accounts: Table<address, ID>, // admin -> account_id
        total_enterprise_volume: u64,
        total_enterprise_savings: u64,
        validator_pools: Table<address, ValidatorPool>,
        admin: address,
    }

    // Dedicated validator pool for enterprise clients
    public struct ValidatorPool has store {
        pool_id: address,
        validators: vector<address>,
        reserved_capacity: u64,
        allocated_capacity: u64,
        enterprise_clients: vector<address>,
        performance_metrics: PoolMetrics,
    }

    // Pool performance tracking
    public struct PoolMetrics has store {
        average_latency: u64,
        success_rate: u64,
        total_transactions: u64,
        uptime_percentage: u64,
        last_update: u64,
    }

    // Gas allocation for monthly budgets
    public struct GasAllocation has key, store {
        id: UID,
        corporate_account: address,
        allocated_amount: u64,
        used_amount: u64,
        month: u64,
        year: u64,
        expires_at: u64,
    }

    // Enterprise gas pool for bulk purchasing
    public struct EnterpriseGasPool has key {
        id: UID,
        company_accounts: vector<address>,
        total_gas_reserved: u64,
        gas_reserve_balance: Balance<SUI>,
        bulk_discount_rate: u64,
        minimum_purchase: u64,
        pool_admin: address,
    }

    // Events
    public struct CorporateAccountCreated has copy, drop {
        account_id: ID,
        company_name: String,
        admin: address,
        monthly_budget: u64,
        discount_tier: u8,
    }

    public struct GasPurchased has copy, drop {
        account_id: ID,
        company_name: String,
        amount: u64,
        discount_applied: u64,
        final_price: u64,
        remaining_budget: u64,
    }

    public struct BudgetReset has copy, drop {
        account_id: ID,
        company_name: String,
        new_budget: u64,
        previous_usage: u64,
        reset_timestamp: u64,
    }

    public struct ValidatorPoolCreated has copy, drop {
        pool_id: address,
        validators: vector<address>,
        reserved_capacity: u64,
        enterprise_client: address,
    }

    public struct DiscountTierUpgraded has copy, drop {
        account_id: ID,
        company_name: String,
        old_tier: u8,
        new_tier: u8,
        new_discount_rate: u64,
    }

    // Initialize enterprise system
    fun init(ctx: &mut TxContext) {
        let registry = EnterpriseRegistry {
            id: object::new(ctx),
            corporate_accounts: table::new(ctx),
            total_enterprise_volume: 0,
            total_enterprise_savings: 0,
            validator_pools: table::new(ctx),
            admin: tx_context::sender(ctx),
        };
        transfer::share_object(registry);
    }

    // Create corporate account
    public entry fun create_corporate_account(
        registry: &mut EnterpriseRegistry,
        company_name: vector<u8>,
        monthly_budget: u64,
        auto_renewal: bool,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let admin = tx_context::sender(ctx);
        
        let account = CorporateAccount {
            id: object::new(ctx),
            company_name: string::utf8(company_name),
            admin,
            authorized_users: table::new(ctx),
            monthly_gas_budget: monthly_budget,
            current_month_usage: 0,
            total_lifetime_usage: 0,
            auto_renewal,
            discount_tier: 0, // Start with no tier
            dedicated_validator_pool: option::none(),
            created_at: current_time,
            last_budget_reset: current_time,
        };

        let account_id = object::uid_to_inner(&account.id);
        table::add(&mut registry.corporate_accounts, admin, account_id);

        event::emit(CorporateAccountCreated {
            account_id,
            company_name: account.company_name,
            admin,
            monthly_budget,
            discount_tier: 0,
        });

        transfer::transfer(account, admin);
    }

    // Add authorized user to corporate account
    public entry fun add_authorized_user(
        account: &mut CorporateAccount,
        user: address,
        ctx: &mut TxContext
    ) {
        assert!(account.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        table::add(&mut account.authorized_users, user, true);
    }

    // Calculate volume discount
    fun calculate_volume_discount(lifetime_usage: u64): (u8, u64) {
        if (lifetime_usage >= TIER_PLATINUM) {
            (4, DISCOUNT_PLATINUM)
        } else if (lifetime_usage >= TIER_GOLD) {
            (3, DISCOUNT_GOLD)
        } else if (lifetime_usage >= TIER_SILVER) {
            (2, DISCOUNT_SILVER)
        } else if (lifetime_usage >= TIER_BRONZE) {
            (1, DISCOUNT_BRONZE)
        } else {
            (0, 0)
        }
    }

    // Update discount tier based on usage
    public entry fun update_discount_tier(
        account: &mut CorporateAccount,
        ctx: &mut TxContext
    ) {
        let (new_tier, new_discount) = calculate_volume_discount(account.total_lifetime_usage);
        
        if (new_tier > account.discount_tier) {
            let old_tier = account.discount_tier;
            account.discount_tier = new_tier;
            
            event::emit(DiscountTierUpgraded {
                account_id: object::uid_to_inner(&account.id),
                company_name: account.company_name,
                old_tier,
                new_tier,
                new_discount_rate: new_discount,
            });
        }
    }

    // Purchase gas with enterprise discount
    public entry fun enterprise_gas_purchase(
        registry: &mut EnterpriseRegistry,
        account: &mut CorporateAccount,
        payment: Coin<SUI>,
        gas_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(
            account.admin == sender || table::contains(&account.authorized_users, sender),
            E_UNAUTHORIZED
        );

        // Check monthly budget
        assert!(
            account.current_month_usage + gas_amount <= account.monthly_gas_budget,
            E_BUDGET_EXCEEDED
        );

        // Calculate discount
        let (_, discount_rate) = calculate_volume_discount(account.total_lifetime_usage);
        let base_price = gas_amount * 1000; // Base price in MIST
        let discount_amount = (base_price * discount_rate) / 10000;
        let final_price = base_price - discount_amount;

        assert!(coin::value(&payment) >= final_price, E_INSUFFICIENT_BUDGET);

        // Update usage
        account.current_month_usage = account.current_month_usage + gas_amount;
        account.total_lifetime_usage = account.total_lifetime_usage + gas_amount;

        // Update registry stats
        registry.total_enterprise_volume = registry.total_enterprise_volume + gas_amount;
        registry.total_enterprise_savings = registry.total_enterprise_savings + discount_amount;

        // Process payment
        transfer::public_transfer(payment, @0x0);

        event::emit(GasPurchased {
            account_id: object::uid_to_inner(&account.id),
            company_name: account.company_name,
            amount: gas_amount,
            discount_applied: discount_amount,
            final_price,
            remaining_budget: account.monthly_gas_budget - account.current_month_usage,
        });

        // Check for tier upgrade
        update_discount_tier(account, ctx);
    }

    // Reset monthly budget (should be called monthly)
    public entry fun reset_monthly_budget(
        account: &mut CorporateAccount,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(account.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        let current_time = clock::timestamp_ms(clock);
        let month_in_ms = 30 * 24 * 60 * 60 * 1000; // Approximately 30 days
        
        assert!(current_time >= account.last_budget_reset + month_in_ms, E_UNAUTHORIZED);

        let previous_usage = account.current_month_usage;
        account.current_month_usage = 0;
        account.last_budget_reset = current_time;

        event::emit(BudgetReset {
            account_id: object::uid_to_inner(&account.id),
            company_name: account.company_name,
            new_budget: account.monthly_gas_budget,
            previous_usage,
            reset_timestamp: current_time,
        });
    }

    // Create dedicated validator pool
    public entry fun create_validator_pool(
        registry: &mut EnterpriseRegistry,
        validators: vector<address>,
        reserved_capacity: u64,
        enterprise_client: address,
        ctx: &mut TxContext
    ) {
        assert!(registry.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        let pool_id = tx_context::fresh_object_address(ctx);
        
        let pool = ValidatorPool {
            pool_id,
            validators,
            reserved_capacity,
            allocated_capacity: 0,
            enterprise_clients: vector::singleton(enterprise_client),
            performance_metrics: PoolMetrics {
                average_latency: 0,
                success_rate: 10000, // 100%
                total_transactions: 0,
                uptime_percentage: 10000, // 100%
                last_update: 0,
            },
        };

        table::add(&mut registry.validator_pools, pool_id, pool);

        event::emit(ValidatorPoolCreated {
            pool_id,
            validators,
            reserved_capacity,
            enterprise_client,
        });
    }

    // Assign dedicated validator pool to corporate account
    public entry fun assign_validator_pool(
        registry: &EnterpriseRegistry,
        account: &mut CorporateAccount,
        pool_id: address,
        ctx: &mut TxContext
    ) {
        assert!(registry.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        assert!(table::contains(&registry.validator_pools, pool_id), E_ACCOUNT_NOT_FOUND);
        
        account.dedicated_validator_pool = option::some(pool_id);
    }

    // Create enterprise gas pool for bulk purchasing
    public entry fun create_enterprise_gas_pool(
        company_accounts: vector<address>,
        minimum_purchase: u64,
        bulk_discount_rate: u64,
        ctx: &mut TxContext
    ) {
        let pool = EnterpriseGasPool {
            id: object::new(ctx),
            company_accounts,
            total_gas_reserved: 0,
            gas_reserve_balance: balance::zero<SUI>(),
            bulk_discount_rate,
            minimum_purchase,
            pool_admin: tx_context::sender(ctx),
        };

        transfer::share_object(pool);
    }

    // Bulk purchase gas for enterprise pool
    public entry fun bulk_purchase_gas(
        pool: &mut EnterpriseGasPool,
        payment: Coin<SUI>,
        gas_amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(pool.pool_admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        assert!(gas_amount >= pool.minimum_purchase, E_INVALID_ALLOCATION);

        let base_price = gas_amount * 1000;
        let discount_amount = (base_price * pool.bulk_discount_rate) / 10000;
        let final_price = base_price - discount_amount;

        assert!(coin::value(&payment) >= final_price, E_INSUFFICIENT_BUDGET);

        pool.total_gas_reserved = pool.total_gas_reserved + gas_amount;
        balance::join(&mut pool.gas_reserve_balance, coin::into_balance(payment));
    }

    // View functions
    public fun get_corporate_account_info(account: &CorporateAccount): (String, address, u64, u64, u64, u8, Option<address>) {
        (
            account.company_name,
            account.admin,
            account.monthly_gas_budget,
            account.current_month_usage,
            account.total_lifetime_usage,
            account.discount_tier,
            account.dedicated_validator_pool
        )
    }

    public fun get_discount_info(lifetime_usage: u64): (u8, u64) {
        calculate_volume_discount(lifetime_usage)
    }

    public fun get_enterprise_stats(registry: &EnterpriseRegistry): (u64, u64) {
        (registry.total_enterprise_volume, registry.total_enterprise_savings)
    }

    public fun get_validator_pool_info(registry: &EnterpriseRegistry, pool_id: address): (vector<address>, u64, u64) {
        let pool = table::borrow(&registry.validator_pools, pool_id);
        (pool.validators, pool.reserved_capacity, pool.allocated_capacity)
    }
} 