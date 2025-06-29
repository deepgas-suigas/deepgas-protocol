module gas_futures::presale {
    use std::option;
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::clock::{Self, Clock};

    use gas_futures::gfs_governance::{Self, GFS_GOVERNANCE};

    // Errors
    const E_PRESALE_NOT_ACTIVE: u64 = 1;
    const E_INVALID_AMOUNT: u64 = 2;
    const E_INSUFFICIENT_TOKENS: u64 = 3;
    const E_UNAUTHORIZED: u64 = 4;
    const E_PRESALE_ENDED: u64 = 5;

    // Constants
    const GFS_PER_SUI: u64 = 550; // 1 SUI = 550 GFS
    const MIN_PURCHASE_SUI: u64 = 200_000_000; // 0.2 SUI in MIST
    const MAX_PURCHASE_SUI: u64 = 100_000_000_000; // 100 SUI in MIST
    const GFS_DECIMALS: u8 = 9;

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
    }

    public struct PresaleCap has key {
        id: UID,
    }

    // Events
    public struct TokensPurchased has copy, drop {
        buyer: address,
        sui_amount: u64,
        gfs_amount: u64,
        timestamp: u64,
    }

    public struct PresaleInitialized has copy, drop {
        admin: address,
        total_tokens: u64,
        start_time: u64,
        end_time: u64,
    }

    // Initialize presale
    public entry fun initialize_presale(
        governance_registry: &mut gfs_governance::GovernanceRegistry,
        total_tokens_for_sale: u64,
        start_time: u64,
        end_time: u64,
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
        };

        let presale_cap = PresaleCap {
            id: object::new(ctx),
        };

        event::emit(PresaleInitialized {
            admin,
            total_tokens: total_tokens_for_sale,
            start_time,
            end_time,
        });

        transfer::share_object(presale_config);
        transfer::transfer(presale_cap, admin);
    }

    // Buy GFS tokens with SUI
    public entry fun buy_tokens(
        presale_config: &mut PresaleConfig,
        payment: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let buyer = tx_context::sender(ctx);
        let sui_amount = coin::value(&payment);

        // Validations
        assert!(presale_config.is_active, E_PRESALE_NOT_ACTIVE);
        assert!(current_time >= presale_config.start_time, E_PRESALE_NOT_ACTIVE);
        assert!(current_time <= presale_config.end_time, E_PRESALE_ENDED);
        assert!(sui_amount >= MIN_PURCHASE_SUI, E_INVALID_AMOUNT);
        assert!(sui_amount <= MAX_PURCHASE_SUI, E_INVALID_AMOUNT);

        // Calculate GFS tokens to give
        let gfs_amount = calculate_gfs_amount(sui_amount);
        
        // Check if enough tokens available
        assert!(
            balance::value(&presale_config.gfs_treasury) >= gfs_amount,
            E_INSUFFICIENT_TOKENS
        );

        // Update presale state
        presale_config.tokens_sold = presale_config.tokens_sold + gfs_amount;
        balance::join(&mut presale_config.sui_collected, coin::into_balance(payment));

        // Transfer GFS tokens to buyer
        let gfs_tokens = coin::take(&mut presale_config.gfs_treasury, gfs_amount, ctx);
        transfer::public_transfer(gfs_tokens, buyer);

        // Emit event
        event::emit(TokensPurchased {
            buyer,
            sui_amount,
            gfs_amount,
            timestamp: current_time,
        });
    }

    // Calculate GFS amount from SUI
    fun calculate_gfs_amount(sui_amount: u64): u64 {
        // Convert SUI (MIST) to GFS with proper decimals
        // sui_amount is in MIST (1 SUI = 1,000,000,000 MIST)
        // We want: 1 SUI = 550 GFS
        // GFS has 9 decimals, so we need to return the amount in smallest GFS units
        
        // Simple calculation: sui_amount * GFS_PER_SUI
        // This gives us the correct amount in GFS smallest units
        // Example: 200_000_000 MIST (0.2 SUI) * 550 = 110_000_000_000 (110 GFS with 9 decimals)
        sui_amount * GFS_PER_SUI
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
        
        let sui_amount = balance::value(&presale_config.sui_collected);
        if (sui_amount > 0) {
            let sui_coins = coin::take(&mut presale_config.sui_collected, sui_amount, ctx);
            transfer::public_transfer(sui_coins, tx_context::sender(ctx));
        };
    }

    // View functions
    public fun get_presale_info(presale_config: &PresaleConfig): (bool, u64, u64, u64, u64) {
        (
            presale_config.is_active,
            presale_config.total_tokens_for_sale,
            presale_config.tokens_sold,
            balance::value(&presale_config.sui_collected),
            balance::value(&presale_config.gfs_treasury)
        )
    }

    public fun calculate_gfs_for_sui(sui_amount: u64): u64 {
        calculate_gfs_amount(sui_amount)
    }
} 