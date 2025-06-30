module gas_futures::presale {
    use std::option::{Self, Option};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::table::{Self, Table};
    use std::vector;
    use std::string::{Self, String};

    use gas_futures::gfs_governance::{Self, GFS_GOVERNANCE};

    // Errors
    const E_PRESALE_NOT_ACTIVE: u64 = 1;
    const E_INVALID_AMOUNT: u64 = 2;
    const E_INSUFFICIENT_TOKENS: u64 = 3;
    const E_UNAUTHORIZED: u64 = 4;
    const E_PRESALE_ENDED: u64 = 5;
    const E_ALLOCATION_EXCEEDED: u64 = 6;
    const E_VESTING_NOT_STARTED: u64 = 7;
    const E_NO_TOKENS_TO_CLAIM: u64 = 8;
    const E_REFUND_NOT_AVAILABLE: u64 = 9;

    // Constants
    const GFS_PER_SUI_TIER1: u64 = 600; // Early bird: 1 SUI = 600 GFS
    const GFS_PER_SUI_TIER2: u64 = 550; // Regular: 1 SUI = 550 GFS
    const GFS_PER_SUI_TIER3: u64 = 500; // Final: 1 SUI = 500 GFS
    
    const MIN_PURCHASE_SUI: u64 = 200_000_000; // 0.2 SUI in MIST
    const MAX_PURCHASE_SUI: u64 = 100_000_000_000; // 100 SUI in MIST
    const MAX_PURCHASE_PER_USER: u64 = 200_000_000_000; // 200 SUI max per user
    const GFS_DECIMALS: u8 = 9;

    // Tier thresholds (in tokens sold)
    const TIER1_THRESHOLD: u64 = 10000000000000; // 10M GFS
    const TIER2_THRESHOLD: u64 = 25000000000000; // 25M GFS

    // Vesting periods (in milliseconds)
    const VESTING_CLIFF: u64 = 2592000000; // 30 days
    const VESTING_PERIOD: u64 = 7776000000; // 90 days
    const VESTING_INTERVALS: u64 = 9; // 9 intervals (10% immediate + 9 monthly releases)

    // Structs
    public struct PresaleConfig has key {
        id: UID,
        admin: address,
        is_active: bool,
        total_tokens_for_sale: u64,
        tokens_sold: u64,
        sui_collected: Balance<SUI>,
        gfs_treasury: Balance<GFS_GOVERNANCE>,
        start_time: u64,
        end_time: u64,
        soft_cap: u64, // Minimum SUI to be raised
        hard_cap: u64, // Maximum SUI to be raised
        participants: Table<address, ParticipantInfo>,
        total_participants: u64,
    }

    public struct ParticipantInfo has store {
        sui_contributed: u64,
        gfs_allocated: u64,
        gfs_claimed: u64,
        last_claim_time: u64,
        vesting_start: u64,
        tier_rate: u64, // Rate at which they bought
    }

    public struct VestingSchedule has key, store {
        id: UID,
        beneficiary: address,
        total_amount: u64,
        claimed_amount: u64,
        start_time: u64,
        cliff_duration: u64,
        vesting_duration: u64,
        interval_duration: u64,
    }

    public struct PresaleCap has key {
        id: UID,
    }

    public struct RefundTicket has key, store {
        id: UID,
        participant: address,
        sui_amount: u64,
        reason: String,
    }

    // Events
    public struct TokensPurchased has copy, drop {
        buyer: address,
        sui_amount: u64,
        gfs_amount: u64,
        tier_rate: u64,
        timestamp: u64,
    }

    public struct PresaleInitialized has copy, drop {
        admin: address,
        total_tokens: u64,
        start_time: u64,
        end_time: u64,
        soft_cap: u64,
        hard_cap: u64,
    }

    public struct TokensClaimed has copy, drop {
        beneficiary: address,
        amount: u64,
        timestamp: u64,
    }

    public struct RefundRequested has copy, drop {
        participant: address,
        sui_amount: u64,
        reason: String,
    }

    // Initialize presale with enhanced features
    public entry fun initialize_presale(
        governance_registry: &mut gfs_governance::GovernanceRegistry,
        total_tokens_for_sale: u64,
        start_time: u64,
        end_time: u64,
        soft_cap: u64,
        hard_cap: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let admin = tx_context::sender(ctx);
        
        // Mint tokens for presale
        let gfs_tokens = gfs_governance::mint_tokens_for_presale(
            governance_registry,
            total_tokens_for_sale,
            ctx
        );

        let presale_config = PresaleConfig {
            id: object::new(ctx),
            admin,
            is_active: true,
            total_tokens_for_sale,
            tokens_sold: 0,
            sui_collected: balance::zero(),
            gfs_treasury: coin::into_balance(gfs_tokens),
            start_time,
            end_time,
            soft_cap,
            hard_cap,
            participants: table::new(ctx),
            total_participants: 0,
        };

        let presale_cap = PresaleCap {
            id: object::new(ctx),
        };

        event::emit(PresaleInitialized {
            admin,
            total_tokens: total_tokens_for_sale,
            start_time,
            end_time,
            soft_cap,
            hard_cap,
        });

        transfer::share_object(presale_config);
        transfer::transfer(presale_cap, admin);
    }

    // Buy tokens with tier pricing
    public entry fun buy_tokens(
        presale_config: &mut PresaleConfig,
        payment: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let buyer = tx_context::sender(ctx);
        let sui_amount = coin::value(&payment);

        // Basic validations
        assert!(presale_config.is_active, E_PRESALE_NOT_ACTIVE);
        assert!(current_time >= presale_config.start_time, E_PRESALE_NOT_ACTIVE);
        assert!(current_time <= presale_config.end_time, E_PRESALE_ENDED);
        assert!(sui_amount >= MIN_PURCHASE_SUI, E_INVALID_AMOUNT);
        assert!(sui_amount <= MAX_PURCHASE_SUI, E_INVALID_AMOUNT);

        // Check hard cap
        let total_sui = balance::value(&presale_config.sui_collected) + sui_amount;
        assert!(total_sui <= presale_config.hard_cap, E_ALLOCATION_EXCEEDED);

        // Check user allocation limit
        let current_contribution = if (table::contains(&presale_config.participants, buyer)) {
            let participant = table::borrow(&presale_config.participants, buyer);
            participant.sui_contributed
        } else {
            0
        };
        assert!(current_contribution + sui_amount <= MAX_PURCHASE_PER_USER, E_ALLOCATION_EXCEEDED);

        // Calculate current tier rate
        let tier_rate = calculate_current_tier_rate(presale_config.tokens_sold);
        let gfs_amount = calculate_gfs_amount_with_tier(sui_amount, tier_rate);

        // Check if enough tokens available
        assert!(
            balance::value(&presale_config.gfs_treasury) >= gfs_amount,
            E_INSUFFICIENT_TOKENS
        );

        // Update participant info
        if (table::contains(&presale_config.participants, buyer)) {
            let participant = table::borrow_mut(&mut presale_config.participants, buyer);
            participant.sui_contributed = participant.sui_contributed + sui_amount;
            participant.gfs_allocated = participant.gfs_allocated + gfs_amount;
        } else {
            let participant_info = ParticipantInfo {
                sui_contributed: sui_amount,
                gfs_allocated: gfs_amount,
                gfs_claimed: 0,
                last_claim_time: 0,
                vesting_start: current_time,
                tier_rate,
            };
            table::add(&mut presale_config.participants, buyer, participant_info);
            presale_config.total_participants = presale_config.total_participants + 1;
        };

        // Update presale state
        presale_config.tokens_sold = presale_config.tokens_sold + gfs_amount;
        balance::join(&mut presale_config.sui_collected, coin::into_balance(payment));

        // Create vesting schedule (10% immediate + 90% vested over 90 days)
        let immediate_amount = gfs_amount / 10; // 10% immediate
        let vested_amount = gfs_amount - immediate_amount; // 90% vested

        // Transfer immediate amount
        if (immediate_amount > 0) {
            let immediate_tokens = coin::take(&mut presale_config.gfs_treasury, immediate_amount, ctx);
            transfer::public_transfer(immediate_tokens, buyer);
        };

        // Create vesting schedule for remaining amount
        if (vested_amount > 0) {
            let vesting_schedule = VestingSchedule {
                id: object::new(ctx),
                beneficiary: buyer,
                total_amount: vested_amount,
                claimed_amount: 0,
                start_time: current_time,
                cliff_duration: VESTING_CLIFF,
                vesting_duration: VESTING_PERIOD,
                interval_duration: VESTING_PERIOD / VESTING_INTERVALS,
            };
            transfer::transfer(vesting_schedule, buyer);
        };

        // Emit event
        event::emit(TokensPurchased {
            buyer,
            sui_amount,
            gfs_amount,
            tier_rate,
            timestamp: current_time,
        });
    }

    // Claim vested tokens
    public entry fun claim_vested_tokens(
        presale_config: &mut PresaleConfig,
        vesting_schedule: &mut VestingSchedule,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let beneficiary = tx_context::sender(ctx);
        
        assert!(vesting_schedule.beneficiary == beneficiary, E_UNAUTHORIZED);
        assert!(current_time >= vesting_schedule.start_time + vesting_schedule.cliff_duration, E_VESTING_NOT_STARTED);

        let claimable_amount = calculate_claimable_amount(vesting_schedule, current_time);
        assert!(claimable_amount > 0, E_NO_TOKENS_TO_CLAIM);

        // Update vesting schedule
        vesting_schedule.claimed_amount = vesting_schedule.claimed_amount + claimable_amount;

        // Update participant info
        if (table::contains(&presale_config.participants, beneficiary)) {
            let participant = table::borrow_mut(&mut presale_config.participants, beneficiary);
            participant.gfs_claimed = participant.gfs_claimed + claimable_amount;
            participant.last_claim_time = current_time;
        };

        // Transfer tokens
        let tokens = coin::take(&mut presale_config.gfs_treasury, claimable_amount, ctx);
        transfer::public_transfer(tokens, beneficiary);

        event::emit(TokensClaimed {
            beneficiary,
            amount: claimable_amount,
            timestamp: current_time,
        });
    }

    // Request refund (if soft cap not met)
    public entry fun request_refund(
        presale_config: &PresaleConfig,
        reason: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let participant = tx_context::sender(ctx);
        
        assert!(table::contains(&presale_config.participants, participant), E_UNAUTHORIZED);
        
        // Check if soft cap was not met and presale ended
        let total_raised = balance::value(&presale_config.sui_collected);
        assert!(total_raised < presale_config.soft_cap, E_REFUND_NOT_AVAILABLE);
        assert!(current_time > presale_config.end_time, E_PRESALE_NOT_ACTIVE);

        let participant_info = table::borrow(&presale_config.participants, participant);
        let refund_amount = participant_info.sui_contributed;

        let refund_ticket = RefundTicket {
            id: object::new(ctx),
            participant,
            sui_amount: refund_amount,
            reason: string::utf8(reason),
        };

        event::emit(RefundRequested {
            participant,
            sui_amount: refund_amount,
            reason: string::utf8(reason),
        });

        transfer::transfer(refund_ticket, presale_config.admin);
    }

    // Process refund (admin only)
    public entry fun process_refund(
        presale_config: &mut PresaleConfig,
        refund_ticket: RefundTicket,
        _: &PresaleCap,
        ctx: &mut TxContext
    ) {
        assert!(presale_config.admin == tx_context::sender(ctx), E_UNAUTHORIZED);

        let participant = refund_ticket.participant;
        let refund_amount = refund_ticket.sui_amount;

        // Check if enough SUI available
        assert!(balance::value(&presale_config.sui_collected) >= refund_amount, E_INSUFFICIENT_TOKENS);

        // Process refund
        let refund_coins = coin::take(&mut presale_config.sui_collected, refund_amount, ctx);
        transfer::public_transfer(refund_coins, participant);

        // Update participant status - properly handle the returned value
        if (table::contains(&presale_config.participants, participant)) {
            let participant_info = table::remove(&mut presale_config.participants, participant);
            presale_config.total_participants = presale_config.total_participants - 1;
            
            // Properly destroy the participant info
            let ParticipantInfo { 
                sui_contributed: _, 
                gfs_allocated: _, 
                gfs_claimed: _, 
                last_claim_time: _, 
                vesting_start: _, 
                tier_rate: _ 
            } = participant_info;
        };

        // Destroy refund ticket
        let RefundTicket { id, participant: _, sui_amount: _, reason: _ } = refund_ticket;
        object::delete(id);
    }

    // Admin functions
    public entry fun toggle_presale(
        presale_config: &mut PresaleConfig,
        _: &PresaleCap,
        ctx: &mut TxContext
    ) {
        assert!(presale_config.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        presale_config.is_active = !presale_config.is_active;
    }

    public entry fun withdraw_sui(
        presale_config: &mut PresaleConfig,
        _: &PresaleCap,
        ctx: &mut TxContext
    ) {
        assert!(presale_config.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        // Only allow withdrawal if soft cap is met
        let total_raised = balance::value(&presale_config.sui_collected);
        assert!(total_raised >= presale_config.soft_cap, E_REFUND_NOT_AVAILABLE);
        
        if (total_raised > 0) {
            let sui_coins = coin::take(&mut presale_config.sui_collected, total_raised, ctx);
            transfer::public_transfer(sui_coins, tx_context::sender(ctx));
        };
    }

    public entry fun extend_presale(
        presale_config: &mut PresaleConfig,
        additional_time: u64,
        _: &PresaleCap,
        ctx: &mut TxContext
    ) {
        assert!(presale_config.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        presale_config.end_time = presale_config.end_time + additional_time;
    }

    // Helper functions
    fun calculate_current_tier_rate(tokens_sold: u64): u64 {
        if (tokens_sold < TIER1_THRESHOLD) {
            GFS_PER_SUI_TIER1
        } else if (tokens_sold < TIER2_THRESHOLD) {
            GFS_PER_SUI_TIER2
        } else {
            GFS_PER_SUI_TIER3
        }
    }

    fun calculate_gfs_amount_with_tier(sui_amount: u64, tier_rate: u64): u64 {
        sui_amount * tier_rate
    }

    fun calculate_claimable_amount(vesting_schedule: &VestingSchedule, current_time: u64): u64 {
        if (current_time < vesting_schedule.start_time + vesting_schedule.cliff_duration) {
            return 0
        };

        let elapsed_time = current_time - (vesting_schedule.start_time + vesting_schedule.cliff_duration);
        let intervals_passed = elapsed_time / vesting_schedule.interval_duration;
        
        let total_claimable = if (intervals_passed >= VESTING_INTERVALS) {
            vesting_schedule.total_amount
        } else {
            (vesting_schedule.total_amount * intervals_passed) / VESTING_INTERVALS
        };

        if (total_claimable > vesting_schedule.claimed_amount) {
            total_claimable - vesting_schedule.claimed_amount
        } else {
            0
        }
    }

    // View functions
    public fun get_presale_info(presale_config: &PresaleConfig): (bool, u64, u64, u64, u64, u64, u64, u64) {
        (
            presale_config.is_active,
            presale_config.total_tokens_for_sale,
            presale_config.tokens_sold,
            balance::value(&presale_config.sui_collected),
            balance::value(&presale_config.gfs_treasury),
            presale_config.soft_cap,
            presale_config.hard_cap,
            presale_config.total_participants
        )
    }

    public fun get_participant_info(presale_config: &PresaleConfig, participant: address): (u64, u64, u64, u64, u64) {
        if (table::contains(&presale_config.participants, participant)) {
            let info = table::borrow(&presale_config.participants, participant);
            (
                info.sui_contributed,
                info.gfs_allocated,
                info.gfs_claimed,
                info.tier_rate,
                info.vesting_start
            )
        } else {
            (0, 0, 0, 0, 0)
        }
    }

    public fun get_current_tier_info(presale_config: &PresaleConfig): (u64, u64, u64) {
        let current_rate = calculate_current_tier_rate(presale_config.tokens_sold);
        let remaining_in_tier = if (presale_config.tokens_sold < TIER1_THRESHOLD) {
            TIER1_THRESHOLD - presale_config.tokens_sold
        } else if (presale_config.tokens_sold < TIER2_THRESHOLD) {
            TIER2_THRESHOLD - presale_config.tokens_sold
        } else {
            0
        };
        
        (current_rate, remaining_in_tier, presale_config.tokens_sold)
    }

    public fun calculate_gfs_for_sui(sui_amount: u64, tokens_sold: u64): u64 {
        let tier_rate = calculate_current_tier_rate(tokens_sold);
        calculate_gfs_amount_with_tier(sui_amount, tier_rate)
    }

    public fun get_vesting_info(vesting_schedule: &VestingSchedule, current_time: u64): (u64, u64, u64, bool) {
        let claimable = calculate_claimable_amount(vesting_schedule, current_time);
        let is_cliff_passed = current_time >= vesting_schedule.start_time + vesting_schedule.cliff_duration;
        
        (
            vesting_schedule.total_amount,
            vesting_schedule.claimed_amount,
            claimable,
            is_cliff_passed
        )
    }

    public fun get_purchase_limits(): (u64, u64, u64) {
        (MIN_PURCHASE_SUI, MAX_PURCHASE_SUI, MAX_PURCHASE_PER_USER)
    }
} 