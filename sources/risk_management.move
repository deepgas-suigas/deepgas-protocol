/// Risk Management for Gas Futures
/// Handles insurance funds, liquidations, and risk assessment
module gas_futures::risk_management {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::table::{Self, Table};

    // Error codes
    const E_INSUFFICIENT_FUNDS: u64 = 1;
    const E_UNAUTHORIZED: u64 = 2;
    const E_INVALID_RISK_LEVEL: u64 = 3;
    const E_LIQUIDATION_NOT_REQUIRED: u64 = 4;
    const E_INSURANCE_FUND_DEPLETED: u64 = 5;
    const E_INVALID_COLLATERAL_RATIO: u64 = 6;

    // Risk levels
    const RISK_LOW: u8 = 1;
    const RISK_MEDIUM: u8 = 2;
    const RISK_HIGH: u8 = 3;
    const RISK_CRITICAL: u8 = 4;

    // Risk thresholds (basis points)
    const LOW_RISK_THRESHOLD: u64 = 2000;    // 20%
    const MEDIUM_RISK_THRESHOLD: u64 = 5000; // 50%
    const HIGH_RISK_THRESHOLD: u64 = 8000;   // 80%
    const CRITICAL_RISK_THRESHOLD: u64 = 9500; // 95%

    // Liquidation parameters
    const MIN_COLLATERAL_RATIO: u64 = 12000; // 120%
    const LIQUIDATION_PENALTY: u64 = 1000;   // 10%
    const INSURANCE_FEE_RATE: u64 = 100;     // 1%

    // Insurance fund structure
    public struct InsuranceFund has key {
        id: UID,
        balance: Balance<SUI>,
        total_deposits: u64,
        total_payouts: u64,
        coverage_ratio: u64,
        min_reserve_ratio: u64,
        admin: address,
        last_assessment: u64,
    }

    // Risk position tracking
    public struct RiskPosition has key, store {
        id: UID,
        owner: address,
        collateral_amount: u64,
        borrowed_amount: u64,
        risk_level: u8,
        liquidation_price: u64,
        last_update: u64,
        health_factor: u64,
    }

    // Risk assessment registry
    public struct RiskRegistry has key {
        id: UID,
        positions: Table<address, vector<ID>>, // user -> position IDs
        total_risk_exposure: u64,
        system_health_factor: u64,
        emergency_mode: bool,
        admin: address,
    }

    // Liquidation data
    public struct LiquidationData has key, store {
        id: UID,
        position_id: ID,
        liquidator: address,
        liquidated_amount: u64,
        penalty_amount: u64,
        timestamp: u64,
    }

    // Events
    public struct InsuranceFundDeposit has copy, drop {
        depositor: address,
        amount: u64,
        new_balance: u64,
    }

    public struct InsuranceClaim has copy, drop {
        claimant: address,
        amount: u64,
        reason: vector<u8>,
        remaining_balance: u64,
    }

    public struct RiskAssessment has copy, drop {
        position_id: ID,
        owner: address,
        risk_level: u8,
        health_factor: u64,
        liquidation_price: u64,
    }

    public struct Liquidation has copy, drop {
        position_id: ID,
        owner: address,
        liquidator: address,
        liquidated_amount: u64,
        penalty_amount: u64,
        insurance_payout: u64,
    }

    public struct EmergencyActivated has copy, drop {
        reason: vector<u8>,
        timestamp: u64,
        system_health: u64,
    }

    // Initialize risk management system
    fun init(ctx: &mut TxContext) {
        let insurance_fund = InsuranceFund {
            id: object::new(ctx),
            balance: balance::zero<SUI>(),
            total_deposits: 0,
            total_payouts: 0,
            coverage_ratio: 10000, // 100%
            min_reserve_ratio: 2000, // 20%
            admin: tx_context::sender(ctx),
            last_assessment: 0,
        };

        let risk_registry = RiskRegistry {
            id: object::new(ctx),
            positions: table::new(ctx),
            total_risk_exposure: 0,
            system_health_factor: 10000, // 100%
            emergency_mode: false,
            admin: tx_context::sender(ctx),
        };

        transfer::share_object(insurance_fund);
        transfer::share_object(risk_registry);
    }

    // Deposit into insurance fund
    public entry fun deposit_insurance(
        fund: &mut InsuranceFund,
        payment: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        let amount = coin::value(&payment);
        balance::join(&mut fund.balance, coin::into_balance(payment));
        fund.total_deposits = fund.total_deposits + amount;

        event::emit(InsuranceFundDeposit {
            depositor: tx_context::sender(ctx),
            amount,
            new_balance: balance::value(&fund.balance),
        });
    }

    // Create risk position
    public entry fun create_risk_position(
        registry: &mut RiskRegistry,
        collateral: Coin<SUI>,
        borrowed_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let collateral_amount = coin::value(&collateral);
        let current_time = clock::timestamp_ms(clock);
        
        // Calculate initial risk metrics
        let collateral_ratio = (collateral_amount * 10000) / borrowed_amount;
        assert!(collateral_ratio >= MIN_COLLATERAL_RATIO, E_INVALID_COLLATERAL_RATIO);

        let health_factor = calculate_health_factor(collateral_amount, borrowed_amount);
        let risk_level = assess_risk_level(health_factor);
        let liquidation_price = calculate_liquidation_price(collateral_amount, borrowed_amount);

        let position = RiskPosition {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            collateral_amount,
            borrowed_amount,
            risk_level,
            liquidation_price,
            last_update: current_time,
            health_factor,
        };

        let position_id = object::uid_to_inner(&position.id);
        
        // Update registry
        let sender = tx_context::sender(ctx);
        if (!table::contains(&registry.positions, sender)) {
            table::add(&mut registry.positions, sender, vector::empty<ID>());
        };
        let user_positions = table::borrow_mut(&mut registry.positions, sender);
        vector::push_back(user_positions, position_id);

        registry.total_risk_exposure = registry.total_risk_exposure + borrowed_amount;
        
        event::emit(RiskAssessment {
            position_id,
            owner: sender,
            risk_level,
            health_factor,
            liquidation_price,
        });

        // Store collateral (simplified - in production would use vault)
        transfer::public_transfer(collateral, @0x0);
        transfer::transfer(position, sender);
    }

    // Update risk assessment
    public entry fun update_risk_assessment(
        registry: &mut RiskRegistry,
        position: &mut RiskPosition,
        current_price: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(position.owner == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        let current_time = clock::timestamp_ms(clock);
        
        // Recalculate health factor based on current price
        let adjusted_collateral_value = (position.collateral_amount * current_price) / 1000000;
        let new_health_factor = calculate_health_factor(adjusted_collateral_value, position.borrowed_amount);
        let new_risk_level = assess_risk_level(new_health_factor);
        let new_liquidation_price = calculate_liquidation_price(adjusted_collateral_value, position.borrowed_amount);

        // Update position
        position.health_factor = new_health_factor;
        position.risk_level = new_risk_level;
        position.liquidation_price = new_liquidation_price;
        position.last_update = current_time;

        // Update system health
        update_system_health(registry);

        event::emit(RiskAssessment {
            position_id: object::uid_to_inner(&position.id),
            owner: position.owner,
            risk_level: new_risk_level,
            health_factor: new_health_factor,
            liquidation_price: new_liquidation_price,
        });
    }

    // Liquidate position
    public entry fun liquidate_position(
        registry: &mut RiskRegistry,
        fund: &mut InsuranceFund,
        position: RiskPosition,
        current_price: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        
        // Check if liquidation is required
        let adjusted_collateral_value = (position.collateral_amount * current_price) / 1000000;
        let health_factor = calculate_health_factor(adjusted_collateral_value, position.borrowed_amount);
        assert!(health_factor < 10000, E_LIQUIDATION_NOT_REQUIRED); // Health factor below 100%

        let position_id = object::uid_to_inner(&position.id);
        let liquidated_amount = position.borrowed_amount;
        let penalty_amount = (liquidated_amount * LIQUIDATION_PENALTY) / 10000;
        let total_amount = liquidated_amount + penalty_amount;

        // Check if insurance fund can cover shortfall
        let collateral_shortfall = if (adjusted_collateral_value < total_amount) {
            total_amount - adjusted_collateral_value
        } else {
            0
        };

        let insurance_payout = if (collateral_shortfall > 0) {
            let available_insurance = balance::value(&fund.balance);
            assert!(available_insurance >= collateral_shortfall, E_INSURANCE_FUND_DEPLETED);
            
            // Pay from insurance fund
            let payout = coin::take(&mut fund.balance, collateral_shortfall, ctx);
            transfer::public_transfer(payout, tx_context::sender(ctx));
            fund.total_payouts = fund.total_payouts + collateral_shortfall;
            collateral_shortfall
        } else {
            0
        };

        // Update registry
        registry.total_risk_exposure = registry.total_risk_exposure - liquidated_amount;
        update_system_health(registry);

        event::emit(Liquidation {
            position_id,
            owner: position.owner,
            liquidator: tx_context::sender(ctx),
            liquidated_amount,
            penalty_amount,
            insurance_payout,
        });

        // Create liquidation record
        let liquidation_data = LiquidationData {
            id: object::new(ctx),
            position_id,
            liquidator: tx_context::sender(ctx),
            liquidated_amount,
            penalty_amount,
            timestamp: current_time,
        };

        transfer::transfer(liquidation_data, tx_context::sender(ctx));

        // Destroy position
        let RiskPosition { 
            id, 
            owner: _, 
            collateral_amount: _, 
            borrowed_amount: _, 
            risk_level: _, 
            liquidation_price: _, 
            last_update: _, 
            health_factor: _ 
        } = position;
        object::delete(id);
    }

    // Emergency shutdown
    public entry fun activate_emergency_mode(
        registry: &mut RiskRegistry,
        reason: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(registry.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        registry.emergency_mode = true;
        let current_time = clock::timestamp_ms(clock);

        event::emit(EmergencyActivated {
            reason,
            timestamp: current_time,
            system_health: registry.system_health_factor,
        });
    }

    // Calculate health factor
    fun calculate_health_factor(collateral_value: u64, borrowed_amount: u64): u64 {
        if (borrowed_amount == 0) {
            return 10000 // 100% if no debt
        };
        (collateral_value * 10000) / borrowed_amount
    }

    // Assess risk level based on health factor
    fun assess_risk_level(health_factor: u64): u8 {
        if (health_factor >= HIGH_RISK_THRESHOLD) {
            RISK_LOW
        } else if (health_factor >= MEDIUM_RISK_THRESHOLD) {
            RISK_MEDIUM
        } else if (health_factor >= LOW_RISK_THRESHOLD) {
            RISK_HIGH
        } else {
            RISK_CRITICAL
        }
    }

    // Calculate liquidation price
    fun calculate_liquidation_price(collateral_amount: u64, borrowed_amount: u64): u64 {
        let required_collateral_value = (borrowed_amount * MIN_COLLATERAL_RATIO) / 10000;
        (required_collateral_value * 1000000) / collateral_amount
    }

    // Update system health factor
    fun update_system_health(registry: &mut RiskRegistry) {
        // Simplified system health calculation
        // In production, would aggregate all position health factors
        if (registry.total_risk_exposure == 0) {
            registry.system_health_factor = 10000;
        } else {
            // Calculate weighted average health factor
            registry.system_health_factor = 8500; // Placeholder calculation
        }
    }

    // View functions
    public fun get_insurance_fund_balance(fund: &InsuranceFund): u64 {
        balance::value(&fund.balance)
    }

    public fun get_position_info(position: &RiskPosition): (address, u64, u64, u8, u64, u64) {
        (
            position.owner,
            position.collateral_amount,
            position.borrowed_amount,
            position.risk_level,
            position.liquidation_price,
            position.health_factor
        )
    }

    public fun get_system_health(registry: &RiskRegistry): (u64, bool) {
        (registry.system_health_factor, registry.emergency_mode)
    }
}