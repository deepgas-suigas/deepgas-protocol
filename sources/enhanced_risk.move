/// Enhanced Risk Management and Emergency Mechanisms
/// Provides circuit breakers, emergency protocols, and advanced risk assessment
module gas_futures::enhanced_risk {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::table::{Self, Table};
    use sui::transfer;
    use std::vector;
    use std::option::{Self, Option};

    // Error codes
    const E_EMERGENCY_MODE_ACTIVE: u64 = 1;
    const E_CIRCUIT_BREAKER_TRIGGERED: u64 = 2;
    const E_RISK_LIMIT_EXCEEDED: u64 = 3;
    const E_UNAUTHORIZED: u64 = 4;
    const E_INSUFFICIENT_COLLATERAL: u64 = 5;
    const E_LIQUIDATION_THRESHOLD: u64 = 6;
    const E_SYSTEM_PAUSED: u64 = 7;

    // Risk levels
    const RISK_LEVEL_LOW: u8 = 1;
    const RISK_LEVEL_MEDIUM: u8 = 2;
    const RISK_LEVEL_HIGH: u8 = 3;
    const RISK_LEVEL_CRITICAL: u8 = 4;

    // Circuit breaker thresholds
    const PRICE_VOLATILITY_THRESHOLD: u64 = 2000; // 20%
    const VOLUME_SPIKE_THRESHOLD: u64 = 5000; // 500%
    const LIQUIDATION_CASCADE_THRESHOLD: u64 = 1000; // 10%

    // Emergency system state
    public struct EmergencySystem has key {
        id: UID,
        emergency_mode: bool,
        system_paused: bool,
        circuit_breakers_active: bool,
        last_emergency_timestamp: u64,
        emergency_admin: address,
        emergency_council: vector<address>,
        minimum_council_approval: u64,
        insurance_fund: Balance<SUI>,
        total_insurance_claims: u64,
    }

    // Circuit breaker configuration
    public struct CircuitBreaker has key {
        id: UID,
        price_volatility_breaker: bool,
        volume_spike_breaker: bool,
        liquidation_cascade_breaker: bool,
        daily_loss_limit: u64,
        current_daily_loss: u64,
        last_reset_timestamp: u64,
        trigger_count: u64,
        cooldown_period: u64,
    }

    // Advanced risk metrics
    public struct RiskMetrics has key {
        id: UID,
        system_tvl: u64,
        total_exposure: u64,
        concentration_risk: u64,
        liquidity_risk: u64,
        counterparty_risk: u64,
        market_risk: u64,
        operational_risk: u64,
        stress_test_results: Table<u64, StressTestResult>,
        var_95: u64, // Value at Risk 95%
        expected_shortfall: u64,
        last_risk_assessment: u64,
        insurance_fund: Balance<SUI>,
    }

    // Stress test results
    public struct StressTestResult has store {
        test_scenario: u8,
        projected_loss: u64,
        system_survival: bool,
        recommended_actions: vector<u8>,
        test_timestamp: u64,
    }

    // Enhanced position tracking
    public struct RiskPosition has key, store {
        id: UID,
        owner: address,
        gas_credits_exposure: u64,
        collateral_amount: u64,
        leverage_ratio: u64,
        health_factor: u64,
        liquidation_threshold: u64,
        risk_score: u64,
        last_update: u64,
        margin_call_level: u64,
        auto_liquidation_enabled: bool,
    }

    // Emergency protocol
    public struct EmergencyProtocol has key {
        id: UID,
        protocol_type: u8, // 1: market halt, 2: liquidation freeze, 3: withdrawal limit
        trigger_conditions: vector<u64>,
        auto_trigger_enabled: bool,
        manual_override: bool,
        activation_timestamp: u64,
        estimated_duration: u64,
        affected_users: vector<address>,
        compensation_pool: Balance<SUI>,
    }

    // Insurance claim
    public struct InsuranceClaim has key, store {
        id: UID,
        claimant: address,
        claim_amount: u64,
        incident_type: u8,
        incident_timestamp: u64,
        claim_timestamp: u64,
        status: u8, // 1: pending, 2: approved, 3: rejected, 4: paid
        evidence_hash: vector<u8>,
        assessor: address,
        payout_amount: u64,
    }

    // Events
    public struct EmergencyActivated has copy, drop {
        trigger_reason: vector<u8>,
        trigger_timestamp: u64,
        estimated_resolution_time: u64,
        affected_systems: vector<u8>,
    }

    public struct CircuitBreakerTriggered has copy, drop {
        breaker_type: u8,
        trigger_value: u64,
        threshold: u64,
        trigger_timestamp: u64,
        estimated_cooldown: u64,
    }

    public struct RiskAssessmentUpdated has copy, drop {
        system_risk_level: u8,
        total_exposure: u64,
        var_95: u64,
        recommendations: vector<u8>,
        assessment_timestamp: u64,
    }

    public struct LiquidationTriggered has copy, drop {
        position_id: ID,
        owner: address,
        liquidated_amount: u64,
        remaining_collateral: u64,
        liquidation_penalty: u64,
        liquidator: address,
    }

    public struct InsuranceClaimFiled has copy, drop {
        claim_id: ID,
        claimant: address,
        claim_amount: u64,
        incident_type: u8,
        filed_timestamp: u64,
    }

    // Initialize enhanced risk system
    fun init(ctx: &mut TxContext) {
        let emergency_system = EmergencySystem {
            id: object::new(ctx),
            emergency_mode: false,
            system_paused: false,
            circuit_breakers_active: true,
            last_emergency_timestamp: 0,
            emergency_admin: tx_context::sender(ctx),
            emergency_council: vector::empty<address>(),
            minimum_council_approval: 3,
            insurance_fund: balance::zero<SUI>(),
            total_insurance_claims: 0,
        };

        let circuit_breaker = CircuitBreaker {
            id: object::new(ctx),
            price_volatility_breaker: true,
            volume_spike_breaker: true,
            liquidation_cascade_breaker: true,
            daily_loss_limit: 1000000000, // 1B MIST
            current_daily_loss: 0,
            last_reset_timestamp: 0,
            trigger_count: 0,
            cooldown_period: 3600000, // 1 hour
        };

        let risk_metrics = RiskMetrics {
            id: object::new(ctx),
            system_tvl: 0,
            total_exposure: 0,
            concentration_risk: 0,
            liquidity_risk: 0,
            counterparty_risk: 0,
            market_risk: 0,
            operational_risk: 0,
            stress_test_results: table::new(ctx),
            var_95: 0,
            expected_shortfall: 0,
            last_risk_assessment: 0,
            insurance_fund: balance::zero<SUI>(),
        };

        transfer::share_object(emergency_system);
        transfer::share_object(circuit_breaker);
        transfer::share_object(risk_metrics);
    }

    // Activate emergency mode
    public entry fun activate_emergency_mode(
        emergency_system: &mut EmergencySystem,
        circuit_breaker: &mut CircuitBreaker,
        reason: vector<u8>,
        estimated_duration: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(
            emergency_system.emergency_admin == tx_context::sender(ctx),
            E_UNAUTHORIZED
        );

        let current_time = clock::timestamp_ms(clock);
        emergency_system.emergency_mode = true;
        emergency_system.last_emergency_timestamp = current_time;
        circuit_breaker.price_volatility_breaker = true;
        circuit_breaker.volume_spike_breaker = true;
        circuit_breaker.liquidation_cascade_breaker = true;

        event::emit(EmergencyActivated {
            trigger_reason: reason,
            trigger_timestamp: current_time,
            estimated_resolution_time: current_time + estimated_duration,
            affected_systems: b"all_systems",
        });
    }

    // Check and trigger circuit breakers
    public entry fun check_circuit_breakers(
        emergency_system: &mut EmergencySystem,
        circuit_breaker: &mut CircuitBreaker,
        risk_metrics: &mut RiskMetrics,
        price_change: u64,
        volume_change: u64,
        liquidation_rate: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        
        // Check price volatility
        if (circuit_breaker.price_volatility_breaker && 
            price_change > PRICE_VOLATILITY_THRESHOLD) {
            trigger_circuit_breaker(emergency_system, circuit_breaker, 1, price_change, current_time);
        };

        // Check volume spike
        if (circuit_breaker.volume_spike_breaker && 
            volume_change > VOLUME_SPIKE_THRESHOLD) {
            trigger_circuit_breaker(emergency_system, circuit_breaker, 2, volume_change, current_time);
        };

        // Check liquidation cascade
        if (circuit_breaker.liquidation_cascade_breaker && 
            liquidation_rate > LIQUIDATION_CASCADE_THRESHOLD) {
            trigger_circuit_breaker(emergency_system, circuit_breaker, 3, liquidation_rate, current_time);
        };

        // Update risk metrics
        update_risk_metrics(risk_metrics, price_change, volume_change, liquidation_rate, current_time);
    }

    // Trigger specific circuit breaker
    fun trigger_circuit_breaker(
        emergency_system: &mut EmergencySystem,
        circuit_breaker: &mut CircuitBreaker,
        breaker_type: u8,
        trigger_value: u64,
        timestamp: u64
    ) {
        circuit_breaker.trigger_count = circuit_breaker.trigger_count + 1;
        emergency_system.circuit_breakers_active = true;

        let threshold = if (breaker_type == 1) {
            PRICE_VOLATILITY_THRESHOLD
        } else if (breaker_type == 2) {
            VOLUME_SPIKE_THRESHOLD
        } else {
            LIQUIDATION_CASCADE_THRESHOLD
        };

        event::emit(CircuitBreakerTriggered {
            breaker_type,
            trigger_value,
            threshold,
            trigger_timestamp: timestamp,
            estimated_cooldown: circuit_breaker.cooldown_period,
        });
    }

    // Update risk metrics
    fun update_risk_metrics(
        risk_metrics: &mut RiskMetrics,
        price_volatility: u64,
        volume_change: u64,
        liquidation_rate: u64,
        timestamp: u64
    ) {
        // Calculate VaR and Expected Shortfall (simplified)
        risk_metrics.var_95 = calculate_var_95(price_volatility, volume_change);
        risk_metrics.expected_shortfall = calculate_expected_shortfall(risk_metrics.var_95);
        
        // Update market risk based on volatility
        risk_metrics.market_risk = price_volatility;
        
        // Update liquidity risk based on volume changes
        risk_metrics.liquidity_risk = if (volume_change > 1000) {
            (RISK_LEVEL_HIGH as u64)
        } else if (volume_change > 500) {
            (RISK_LEVEL_MEDIUM as u64)
        } else {
            (RISK_LEVEL_LOW as u64)
        };

        risk_metrics.last_risk_assessment = timestamp;

        // Determine overall system risk level
        let system_risk_level = calculate_system_risk_level(risk_metrics);

        event::emit(RiskAssessmentUpdated {
            system_risk_level,
            total_exposure: risk_metrics.total_exposure,
            var_95: risk_metrics.var_95,
            recommendations: b"monitor_closely",
            assessment_timestamp: timestamp,
        });
    }

    // Calculate Value at Risk (simplified)
    fun calculate_var_95(price_volatility: u64, volume_change: u64): u64 {
        // Simplified VaR calculation
        let base_var = (price_volatility * 1000) / 100; // Convert to MIST
        let volume_adjustment = if (volume_change > 1000) {
            base_var * 150 / 100 // 50% increase for high volume
        } else {
            base_var
        };
        volume_adjustment
    }

    // Calculate Expected Shortfall
    fun calculate_expected_shortfall(var_95: u64): u64 {
        // Expected Shortfall is typically 1.2-1.5x VaR for normal distributions
        var_95 * 130 / 100
    }

    // Calculate overall system risk level
    fun calculate_system_risk_level(risk_metrics: &RiskMetrics): u8 {
        let mut risk_factors = 0;
        
        if (risk_metrics.market_risk > 1500) risk_factors = risk_factors + 1;
        if (risk_metrics.liquidity_risk >= (RISK_LEVEL_HIGH as u64)) risk_factors = risk_factors + 1;
        if (risk_metrics.concentration_risk > 5000) risk_factors = risk_factors + 1;
        if (risk_metrics.counterparty_risk > 3000) risk_factors = risk_factors + 1;

        if (risk_factors >= 3) {
            RISK_LEVEL_CRITICAL
        } else if (risk_factors >= 2) {
            RISK_LEVEL_HIGH
        } else if (risk_factors >= 1) {
            RISK_LEVEL_MEDIUM
        } else {
            RISK_LEVEL_LOW
        }
    }

    // Create risk position for user
    public entry fun create_risk_position(
        gas_credits_exposure: u64,
        collateral: Coin<SUI>,
        leverage_ratio: u64,
        auto_liquidation: bool,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let collateral_amount = coin::value(&collateral);
        
        let health_factor = calculate_health_factor(
            gas_credits_exposure,
            collateral_amount,
            leverage_ratio
        );

        let position = RiskPosition {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            gas_credits_exposure,
            collateral_amount,
            leverage_ratio,
            health_factor,
            liquidation_threshold: 8000, // 80%
            risk_score: calculate_risk_score(leverage_ratio, health_factor),
            last_update: current_time,
            margin_call_level: 9000, // 90%
            auto_liquidation_enabled: auto_liquidation,
        };

        // Store collateral
        transfer::public_transfer(collateral, @0x0); // Treasury

        transfer::transfer(position, tx_context::sender(ctx));
    }

    // Calculate health factor
    fun calculate_health_factor(
        exposure: u64,
        collateral: u64,
        leverage: u64
    ): u64 {
        if (exposure == 0) {
            return 10000 // 100% healthy
        };
        
        let required_collateral = exposure * leverage / 10000;
        if (collateral >= required_collateral) {
            (collateral * 10000) / required_collateral
        } else {
            (collateral * 10000) / required_collateral
        }
    }

    // Calculate risk score
    fun calculate_risk_score(leverage: u64, health_factor: u64): u64 {
        let leverage_risk = if (leverage > 500) { // >5x leverage
            5000
        } else if (leverage > 300) { // >3x leverage
            3000
        } else if (leverage > 200) { // >2x leverage
            2000
        } else {
            1000
        };

        let health_risk = if (health_factor < 8000) { // <80%
            5000
        } else if (health_factor < 9000) { // <90%
            3000
        } else if (health_factor < 9500) { // <95%
            2000
        } else {
            1000
        };

        leverage_risk + health_risk
    }

    // Trigger liquidation
    public entry fun trigger_liquidation(
        emergency_system: &mut EmergencySystem,
        position: &mut RiskPosition,
        liquidation_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!emergency_system.emergency_mode, E_EMERGENCY_MODE_ACTIVE);
        assert!(position.health_factor < position.liquidation_threshold, E_LIQUIDATION_THRESHOLD);

        let current_time = clock::timestamp_ms(clock);
        let liquidation_penalty = liquidation_amount * 500 / 10000; // 5% penalty
        
        position.gas_credits_exposure = position.gas_credits_exposure - liquidation_amount;
        position.collateral_amount = position.collateral_amount - liquidation_penalty;
        position.last_update = current_time;

        // Recalculate health factor
        position.health_factor = calculate_health_factor(
            position.gas_credits_exposure,
            position.collateral_amount,
            position.leverage_ratio
        );

        event::emit(LiquidationTriggered {
            position_id: object::uid_to_inner(&position.id),
            owner: position.owner,
            liquidated_amount: liquidation_amount,
            remaining_collateral: position.collateral_amount,
            liquidation_penalty,
            liquidator: tx_context::sender(ctx),
        });
    }

    // File insurance claim
    public entry fun file_insurance_claim(
        emergency_system: &mut EmergencySystem,
        claim_amount: u64,
        incident_type: u8,
        evidence_hash: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        
        let claim = InsuranceClaim {
            id: object::new(ctx),
            claimant: tx_context::sender(ctx),
            claim_amount,
            incident_type,
            incident_timestamp: current_time - 86400000, // Incident 1 day ago (example)
            claim_timestamp: current_time,
            status: 1, // Pending
            evidence_hash,
            assessor: emergency_system.emergency_admin,
            payout_amount: 0,
        };

        emergency_system.total_insurance_claims = emergency_system.total_insurance_claims + 1;

        event::emit(InsuranceClaimFiled {
            claim_id: object::uid_to_inner(&claim.id),
            claimant: tx_context::sender(ctx),
            claim_amount,
            incident_type,
            filed_timestamp: current_time,
        });

        transfer::transfer(claim, tx_context::sender(ctx));
    }

    // Run stress test
    public entry fun run_stress_test(
        risk_metrics: &mut RiskMetrics,
        scenario: u8,
        stress_parameters: vector<u64>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        
        // Simplified stress test calculation
        let projected_loss = if (scenario == 1) { // Market crash scenario
            risk_metrics.total_exposure * 2000 / 10000 // 20% loss
        } else if (scenario == 2) { // Liquidity crisis
            risk_metrics.total_exposure * 1500 / 10000 // 15% loss
        } else { // Black swan event
            risk_metrics.total_exposure * 3000 / 10000 // 30% loss
        };

        let system_survival = projected_loss < balance::value(&risk_metrics.insurance_fund);

        let test_result = StressTestResult {
            test_scenario: scenario,
            projected_loss,
            system_survival,
            recommended_actions: if (system_survival) b"continue_operations" else b"emergency_protocols",
            test_timestamp: current_time,
        };

        table::add(&mut risk_metrics.stress_test_results, current_time, test_result);
    }

    // View functions
    public fun get_emergency_status(emergency_system: &EmergencySystem): (bool, bool, bool, u64) {
        (
            emergency_system.emergency_mode,
            emergency_system.system_paused,
            emergency_system.circuit_breakers_active,
            emergency_system.last_emergency_timestamp
        )
    }

    public fun get_risk_metrics(risk_metrics: &RiskMetrics): (u64, u64, u64, u64, u64) {
        (
            risk_metrics.total_exposure,
            risk_metrics.var_95,
            risk_metrics.expected_shortfall,
            risk_metrics.market_risk,
            risk_metrics.last_risk_assessment
        )
    }

    public fun get_position_health(position: &RiskPosition): (u64, u64, u64, bool) {
        (
            position.health_factor,
            position.risk_score,
            position.liquidation_threshold,
            position.auto_liquidation_enabled
        )
    }

    public fun get_circuit_breaker_status(circuit_breaker: &CircuitBreaker): (bool, bool, bool, u64) {
        (
            circuit_breaker.price_volatility_breaker,
            circuit_breaker.volume_spike_breaker,
            circuit_breaker.liquidation_cascade_breaker,
            circuit_breaker.trigger_count
        )
    }

    // Reset circuit breakers after cooldown
    public entry fun reset_circuit_breakers(
        emergency_system: &mut EmergencySystem,
        circuit_breaker: &mut CircuitBreaker,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(
            emergency_system.emergency_admin == tx_context::sender(ctx),
            E_UNAUTHORIZED
        );

        let current_time = clock::timestamp_ms(clock);
        let time_since_trigger = current_time - emergency_system.last_emergency_timestamp;
        
        if (time_since_trigger >= circuit_breaker.cooldown_period) {
            circuit_breaker.price_volatility_breaker = false;
            circuit_breaker.volume_spike_breaker = false;
            circuit_breaker.liquidation_cascade_breaker = false;
            emergency_system.circuit_breakers_active = false;
            circuit_breaker.current_daily_loss = 0;
            circuit_breaker.last_reset_timestamp = current_time;
        }
    }

    // Approve insurance claim  
    public entry fun approve_insurance_claim(
        emergency_system: &mut EmergencySystem,
        claim: &mut InsuranceClaim,
        approved_amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(
            emergency_system.emergency_admin == tx_context::sender(ctx),
            E_UNAUTHORIZED
        );
        assert!(claim.status == 1, E_UNAUTHORIZED); // Must be pending

        claim.status = 2; // Approved
        claim.payout_amount = approved_amount;
        claim.assessor = tx_context::sender(ctx);

        // Payout from insurance fund
        if (balance::value(&emergency_system.insurance_fund) >= approved_amount) {
            let payout = balance::split(&mut emergency_system.insurance_fund, approved_amount);
            let payout_coin = coin::from_balance(payout, ctx);
            transfer::public_transfer(payout_coin, claim.claimant);
            claim.status = 4; // Paid
        }
    }

    // Deposit to insurance fund
    public entry fun deposit_insurance_fund(
        emergency_system: &mut EmergencySystem,
        deposit: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        let amount = coin::value(&deposit);
        balance::join(&mut emergency_system.insurance_fund, coin::into_balance(deposit));
    }

    // Pause system operations
    public entry fun pause_system(
        emergency_system: &mut EmergencySystem,
        ctx: &mut TxContext
    ) {
        assert!(
            emergency_system.emergency_admin == tx_context::sender(ctx),
            E_UNAUTHORIZED
        );
        emergency_system.system_paused = true;
    }

    // Resume system operations
    public entry fun resume_system(
        emergency_system: &mut EmergencySystem,
        ctx: &mut TxContext
    ) {
        assert!(
            emergency_system.emergency_admin == tx_context::sender(ctx),
            E_UNAUTHORIZED
        );
        emergency_system.system_paused = false;
        emergency_system.emergency_mode = false;
    }

    // Update risk thresholds
    public entry fun update_risk_thresholds(
        circuit_breaker: &mut CircuitBreaker,
        new_daily_loss_limit: u64,
        new_cooldown_period: u64,
        ctx: &mut TxContext
    ) {
        circuit_breaker.daily_loss_limit = new_daily_loss_limit;
        circuit_breaker.cooldown_period = new_cooldown_period;
    }

    // Monitor position and auto-liquidate if needed
    public entry fun monitor_and_liquidate_position(
        emergency_system: &mut EmergencySystem,
        position: &mut RiskPosition,
        risk_metrics: &mut RiskMetrics,
        current_gas_price: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!emergency_system.system_paused, E_SYSTEM_PAUSED);
        
        let current_time = clock::timestamp_ms(clock);
        
        // Update position health based on current gas price
        let new_exposure_value = position.gas_credits_exposure * current_gas_price / 1000000;
        position.health_factor = calculate_health_factor(
            new_exposure_value,
            position.collateral_amount,
            position.leverage_ratio
        );
        position.last_update = current_time;

        // Auto-liquidate if health factor is below threshold and auto-liquidation is enabled
        if (position.auto_liquidation_enabled && 
            position.health_factor < position.liquidation_threshold) {
            
            let liquidation_amount = position.gas_credits_exposure / 2; // Liquidate 50%
            trigger_liquidation(
                emergency_system,
                position,
                liquidation_amount,
                clock,
                ctx
            );
        }
    }

    // Calculate system-wide concentration risk
    public entry fun calculate_concentration_risk(
        risk_metrics: &mut RiskMetrics,
        largest_position_sizes: vector<u64>,
        clock: &Clock
    ) {
        let current_time = clock::timestamp_ms(clock);
        let mut total_top_10 = 0;
        let mut i = 0;
        let positions_count = vector::length(&largest_position_sizes);
        let max_positions = if (positions_count > 10) 10 else positions_count;

        while (i < max_positions) {
            total_top_10 = total_top_10 + *vector::borrow(&largest_position_sizes, i);
            i = i + 1;
        };

        // Concentration risk = top 10 positions / total exposure
        if (risk_metrics.total_exposure > 0) {
            risk_metrics.concentration_risk = (total_top_10 * 10000) / risk_metrics.total_exposure;
        };

        risk_metrics.last_risk_assessment = current_time;
    }

    // Update system TVL and exposure
    public entry fun update_system_exposure(
        risk_metrics: &mut RiskMetrics,
        new_tvl: u64,
        new_total_exposure: u64,
        new_counterparty_risk: u64
    ) {
        risk_metrics.system_tvl = new_tvl;
        risk_metrics.total_exposure = new_total_exposure;
        risk_metrics.counterparty_risk = new_counterparty_risk;
        
        // Update operational risk based on system size
        risk_metrics.operational_risk = if (new_tvl > 1000000000000) { // >1T MIST
            3000 // High operational risk for large systems
        } else if (new_tvl > 100000000000) { // >100B MIST
            2000 // Medium operational risk
        } else {
            1000 // Low operational risk
        };
    }

    // Emergency position closure
    public entry fun emergency_close_position(
        emergency_system: &mut EmergencySystem,
        position: &mut RiskPosition,
        forced_closure: bool,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(
            emergency_system.emergency_mode || 
            emergency_system.emergency_admin == tx_context::sender(ctx),
            E_UNAUTHORIZED
        );

        let current_time = clock::timestamp_ms(clock);
        let closure_penalty = if (forced_closure) {
            position.gas_credits_exposure * 1000 / 10000 // 10% penalty for forced closure
        } else {
            0
        };

        // Close position
        position.gas_credits_exposure = 0;
        position.collateral_amount = position.collateral_amount - closure_penalty;
        position.health_factor = 10000; // 100% healthy after closure
        position.last_update = current_time;

        event::emit(LiquidationTriggered {
            position_id: object::uid_to_inner(&position.id),
            owner: position.owner,
            liquidated_amount: position.gas_credits_exposure,
            remaining_collateral: position.collateral_amount,
            liquidation_penalty: closure_penalty,
            liquidator: tx_context::sender(ctx),
        });
    }

    // Get comprehensive risk report
    public fun get_comprehensive_risk_report(
        emergency_system: &EmergencySystem,
        circuit_breaker: &CircuitBreaker,
        risk_metrics: &RiskMetrics
    ): (u8, u64, u64, u64, bool, bool) {
        let system_risk_level = calculate_system_risk_level(risk_metrics);
        let insurance_coverage = balance::value(&emergency_system.insurance_fund);
        
        (
            system_risk_level,
            risk_metrics.total_exposure,
            risk_metrics.var_95,
            insurance_coverage,
            emergency_system.emergency_mode,
            emergency_system.circuit_breakers_active
        )
    }

    // Emergency council voting (simplified)
    public entry fun emergency_council_vote(
        emergency_system: &mut EmergencySystem,
        vote_type: u8, // 1: activate emergency, 2: deactivate emergency
        ctx: &mut TxContext
    ) {
        let voter = tx_context::sender(ctx);
        let mut is_council_member = false;
        let mut i = 0;
        
        while (i < vector::length(&emergency_system.emergency_council)) {
            if (*vector::borrow(&emergency_system.emergency_council, i) == voter) {
                is_council_member = true;
                break
            };
            i = i + 1;
        };
        
        assert!(is_council_member, E_UNAUTHORIZED);
        
        // Simplified voting - in production would track individual votes
        if (vote_type == 1) {
            emergency_system.emergency_mode = true;
        } else if (vote_type == 2) {
            emergency_system.emergency_mode = false;
        }
    }
} 