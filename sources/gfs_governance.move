/// GFS Governance Token and DAO System
/// Provides decentralized governance for Gas Futures Platform
module gas_futures::gfs_governance {
    use sui::object::{Self};
    use sui::tx_context::{Self};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::table::{Self, Table};
    use sui::bag::{Self, Bag};
    use std::string::{Self, String};

    // Error codes
    const E_UNAUTHORIZED: u64 = 1;
    const E_INSUFFICIENT_TOKENS: u64 = 2;
    const E_PROPOSAL_NOT_ACTIVE: u64 = 3;
    const E_ALREADY_VOTED: u64 = 4;
    const E_VOTING_PERIOD_ENDED: u64 = 5;
    const E_INSUFFICIENT_VOTING_POWER: u64 = 6;
    const E_PROPOSAL_NOT_PASSED: u64 = 7;
    const E_EXECUTION_WINDOW_EXPIRED: u64 = 8;
    const E_INVALID_PROPOSAL_TYPE: u64 = 9;
    const E_MAX_SUPPLY_EXCEEDED: u64 = 10;

    // Token supply constants
    const MAX_SUPPLY: u64 = 1000000000000000000; // 1 Billion GFS with 9 decimals (1B * 10^9)
    const PRESALE_ALLOCATION: u64 = 100000000000000000; // 100M GFS (10% of total)
    const ECOSYSTEM_ALLOCATION: u64 = 200000000000000000; // 200M GFS (20% of total)
    const TEAM_ALLOCATION: u64 = 150000000000000000; // 150M GFS (15% of total)
    const TREASURY_ALLOCATION: u64 = 150000000000000000; // 150M GFS (15% of total)
    const YIELD_FARMING_ALLOCATION: u64 = 250000000000000000; // 250M GFS (25% of total)
    const LIQUIDITY_ALLOCATION: u64 = 100000000000000000; // 100M GFS (10% of total)
    const RESERVE_ALLOCATION: u64 = 50000000000000000; // 50M GFS (5% of total)

    // Governance constants
    const MIN_PROPOSAL_THRESHOLD: u64 = 1000000000000000; // 1M GFS tokens with decimals to create proposal
    const VOTING_PERIOD: u64 = 604800000; // 7 days in milliseconds
    const EXECUTION_DELAY: u64 = 172800000; // 48 hours in milliseconds
    const EXECUTION_WINDOW: u64 = 259200000; // 72 hours in milliseconds
    const QUORUM_THRESHOLD: u64 = 4000; // 40% quorum required
    const PASSING_THRESHOLD: u64 = 5100; // 51% majority required

    // Proposal types
    const PROPOSAL_PARAMETER_CHANGE: u8 = 1;
    const PROPOSAL_TREASURY_SPEND: u8 = 2;
    const PROPOSAL_UPGRADE: u8 = 3;
    const PROPOSAL_EMERGENCY: u8 = 4;

    // Lock periods for voting power multipliers
    const LOCK_PERIOD_3_MONTHS: u64 = 7776000000; // 90 days in milliseconds
    const LOCK_PERIOD_6_MONTHS: u64 = 15552000000; // 180 days in milliseconds
    const LOCK_PERIOD_12_MONTHS: u64 = 31104000000; // 365 days in milliseconds

    // One-time witness for initialization and coin type
    public struct GFS_GOVERNANCE has drop {}

    // Governance registry
    public struct GovernanceRegistry has key {
        id: UID,
        treasury_cap: TreasuryCap<GFS_GOVERNANCE>,
        treasury_balance: Balance<GFS_GOVERNANCE>,
        total_staked: u64,
        total_voting_power: u64,
        proposal_count: u64,
        proposals: Table<u64, address>, // proposal_id -> proposal_address
        voters: Table<address, VoterInfo>,
        admin: address,
        emergency_mode: bool,
        // Supply tracking
        minted_for_presale: u64,
        minted_for_ecosystem: u64,
        minted_for_team: u64,
        minted_for_treasury: u64,
        minted_for_yield_farming: u64,
        minted_for_liquidity: u64,
        minted_for_reserve: u64,
        total_burned: u64,
    }

    // Voter information
    public struct VoterInfo has store {
        staked_amount: u64,
        voting_power: u64,
        lock_end_time: u64,
        delegation_target: Option<address>,
        total_votes_cast: u64,
    }

    // Staking position
    public struct StakingPosition has key, store {
        id: UID,
        owner: address,
        amount: u64,
        lock_end_time: u64,
        voting_power_multiplier: u64,
        created_at: u64,
    }

    // Governance proposal
    public struct Proposal has key, store {
        id: UID,
        proposal_id: u64,
        proposer: address,
        title: String,
        description: String,
        proposal_type: u8,
        target_contract: Option<address>,
        function_name: Option<String>,
        parameters: Bag,
        voting_start: u64,
        voting_end: u64,
        execution_time: u64,
        yes_votes: u64,
        no_votes: u64,
        total_voting_power_snapshot: u64,
        status: u8, // 0: active, 1: passed, 2: failed, 3: executed, 4: cancelled
        voters: Table<address, bool>, // voter -> has_voted
    }

    // Vote record
    public struct Vote has key, store {
        id: UID,
        proposal_id: u64,
        voter: address,
        vote: bool, // true = yes, false = no
        voting_power: u64,
        timestamp: u64,
    }

    // Treasury proposal data
    public struct TreasuryProposal has key, store {
        id: UID,
        recipient: address,
        amount: u64,
        token_type: String,
        purpose: String,
    }

    // Events
    public struct TokensStaked has copy, drop {
        staker: address,
        amount: u64,
        lock_period: u64,
        voting_power: u64,
    }

    public struct TokensUnstaked has copy, drop {
        staker: address,
        amount: u64,
        voting_power_lost: u64,
    }

    public struct ProposalCreated has copy, drop {
        proposal_id: u64,
        proposer: address,
        title: String,
        proposal_type: u8,
        voting_end: u64,
    }

    public struct VoteCast has copy, drop {
        proposal_id: u64,
        voter: address,
        vote: bool,
        voting_power: u64,
    }

    public struct ProposalExecuted has copy, drop {
        proposal_id: u64,
        executor: address,
        execution_successful: bool,
    }

    public struct DelegationChanged has copy, drop {
        delegator: address,
        old_delegate: Option<address>,
        new_delegate: Option<address>,
        voting_power: u64,
    }

    public struct TokensMinted has copy, drop {
        recipient: address,
        amount: u64,
        allocation_type: u8, // 1: presale, 2: ecosystem, 3: team, etc.
        total_supply: u64,
    }

    public struct TokensBurned has copy, drop {
        burner: address,
        amount: u64,
        total_supply: u64,
        reason: String,
    }

    // Initialize governance system
    fun init(witness: GFS_GOVERNANCE, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            witness,
            9, // 9 decimals
            b"GFS",
            b"Gas Futures Governance Token",
            b"Governance token for Gas Futures Platform",
            option::none(),
            ctx
        );

        let governance = GovernanceRegistry {
            id: object::new(ctx),
            treasury_cap,
            treasury_balance: balance::zero<GFS_GOVERNANCE>(),
            total_staked: 0,
            total_voting_power: 0,
            proposal_count: 0,
            proposals: table::new(ctx),
            voters: table::new(ctx),
            admin: tx_context::sender(ctx),
            emergency_mode: false,
            minted_for_presale: 0,
            minted_for_ecosystem: 0,
            minted_for_team: 0,
            minted_for_treasury: 0,
            minted_for_yield_farming: 0,
            minted_for_liquidity: 0,
            minted_for_reserve: 0,
            total_burned: 0,
        };

        transfer::public_freeze_object(metadata);
        transfer::share_object(governance);
    }

    // Enhanced mint function with allocation control
    public entry fun mint_tokens(
        governance: &mut GovernanceRegistry,
        amount: u64,
        recipient: address,
        allocation_type: u8, // 1: presale, 2: ecosystem, 3: team, 4: treasury, 5: yield_farming, 6: liquidity, 7: reserve
        ctx: &mut TxContext
    ) {
        assert!(governance.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        // Check max supply
        let current_supply = coin::total_supply(&governance.treasury_cap);
        assert!(current_supply + amount <= MAX_SUPPLY, E_MAX_SUPPLY_EXCEEDED);
        
        // Check allocation limits
        if (allocation_type == 1) { // Presale
            assert!(governance.minted_for_presale + amount <= PRESALE_ALLOCATION, E_MAX_SUPPLY_EXCEEDED);
            governance.minted_for_presale = governance.minted_for_presale + amount;
        } else if (allocation_type == 2) { // Ecosystem
            assert!(governance.minted_for_ecosystem + amount <= ECOSYSTEM_ALLOCATION, E_MAX_SUPPLY_EXCEEDED);
            governance.minted_for_ecosystem = governance.minted_for_ecosystem + amount;
        } else if (allocation_type == 3) { // Team
            assert!(governance.minted_for_team + amount <= TEAM_ALLOCATION, E_MAX_SUPPLY_EXCEEDED);
            governance.minted_for_team = governance.minted_for_team + amount;
        } else if (allocation_type == 4) { // Treasury
            assert!(governance.minted_for_treasury + amount <= TREASURY_ALLOCATION, E_MAX_SUPPLY_EXCEEDED);
            governance.minted_for_treasury = governance.minted_for_treasury + amount;
        } else if (allocation_type == 5) { // Yield Farming
            assert!(governance.minted_for_yield_farming + amount <= YIELD_FARMING_ALLOCATION, E_MAX_SUPPLY_EXCEEDED);
            governance.minted_for_yield_farming = governance.minted_for_yield_farming + amount;
        } else if (allocation_type == 6) { // Liquidity
            assert!(governance.minted_for_liquidity + amount <= LIQUIDITY_ALLOCATION, E_MAX_SUPPLY_EXCEEDED);
            governance.minted_for_liquidity = governance.minted_for_liquidity + amount;
        } else if (allocation_type == 7) { // Reserve
            assert!(governance.minted_for_reserve + amount <= RESERVE_ALLOCATION, E_MAX_SUPPLY_EXCEEDED);
            governance.minted_for_reserve = governance.minted_for_reserve + amount;
        };
        
        let tokens = coin::mint(&mut governance.treasury_cap, amount, ctx);
        let new_total_supply = coin::total_supply(&governance.treasury_cap);
        
        event::emit(TokensMinted {
            recipient,
            amount,
            allocation_type,
            total_supply: new_total_supply,
        });
        
        transfer::public_transfer(tokens, recipient);
    }

    // Mint tokens for presale with allocation control
    public fun mint_tokens_for_presale(
        governance: &mut GovernanceRegistry,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<GFS_GOVERNANCE> {
        assert!(governance.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        // Check presale allocation limit
        assert!(governance.minted_for_presale + amount <= PRESALE_ALLOCATION, E_MAX_SUPPLY_EXCEEDED);
        
        // Check max supply
        let current_supply = coin::total_supply(&governance.treasury_cap);
        assert!(current_supply + amount <= MAX_SUPPLY, E_MAX_SUPPLY_EXCEEDED);
        
        governance.minted_for_presale = governance.minted_for_presale + amount;
        
        let tokens = coin::mint(&mut governance.treasury_cap, amount, ctx);
        let new_total_supply = coin::total_supply(&governance.treasury_cap);
        
        event::emit(TokensMinted {
            recipient: @0x0, // Presale contract will receive
            amount,
            allocation_type: 1, // Presale
            total_supply: new_total_supply,
        });
        
        tokens
    }

    // Burn tokens function
    public entry fun burn_tokens(
        governance: &mut GovernanceRegistry,
        tokens: Coin<GFS_GOVERNANCE>,
        reason: vector<u8>,
        ctx: &mut TxContext
    ) {
        let amount = coin::value(&tokens);
        let burner = tx_context::sender(ctx);
        
        // Burn the tokens
        coin::burn(&mut governance.treasury_cap, tokens);
        
        // Update burn tracking
        governance.total_burned = governance.total_burned + amount;
        
        let new_total_supply = coin::total_supply(&governance.treasury_cap);
        
        event::emit(TokensBurned {
            burner,
            amount,
            total_supply: new_total_supply,
            reason: string::utf8(reason),
        });
    }

    // Get allocation information
    public fun get_allocation_info(governance: &GovernanceRegistry): (u64, u64, u64, u64, u64, u64, u64, u64, u64) {
        (
            governance.minted_for_presale,
            governance.minted_for_ecosystem,
            governance.minted_for_team,
            governance.minted_for_treasury,
            governance.minted_for_yield_farming,
            governance.minted_for_liquidity,
            governance.minted_for_reserve,
            governance.total_burned,
            coin::total_supply(&governance.treasury_cap)
        )
    }

    // Get remaining allocations
    public fun get_remaining_allocations(governance: &GovernanceRegistry): (u64, u64, u64, u64, u64, u64, u64) {
        (
            PRESALE_ALLOCATION - governance.minted_for_presale,
            ECOSYSTEM_ALLOCATION - governance.minted_for_ecosystem,
            TEAM_ALLOCATION - governance.minted_for_team,
            TREASURY_ALLOCATION - governance.minted_for_treasury,
            YIELD_FARMING_ALLOCATION - governance.minted_for_yield_farming,
            LIQUIDITY_ALLOCATION - governance.minted_for_liquidity,
            RESERVE_ALLOCATION - governance.minted_for_reserve
        )
    }

    // Get max supply constant
    public fun get_max_supply(): u64 {
        MAX_SUPPLY
    }

    // Stake tokens for voting power
    public entry fun stake_tokens(
        governance: &mut GovernanceRegistry,
        tokens: Coin<GFS_GOVERNANCE>,
        lock_period_months: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let amount = coin::value(&tokens);
        let current_time = clock::timestamp_ms(clock);
        
        // Calculate lock end time and voting power multiplier
        let (lock_end_time, multiplier) = if (lock_period_months == 3) {
            (current_time + LOCK_PERIOD_3_MONTHS, 1000) // 1.0x
        } else if (lock_period_months == 6) {
            (current_time + LOCK_PERIOD_6_MONTHS, 1500) // 1.5x
        } else if (lock_period_months == 12) {
            (current_time + LOCK_PERIOD_12_MONTHS, 2000) // 2.0x
        } else {
            (current_time, 1000) // No lock, 1.0x multiplier
        };

        let voting_power = (amount * multiplier) / 1000;
        let sender = tx_context::sender(ctx);

        // Update or create voter info
        if (table::contains(&governance.voters, sender)) {
            let voter_info = table::borrow_mut(&mut governance.voters, sender);
            voter_info.staked_amount = voter_info.staked_amount + amount;
            voter_info.voting_power = voter_info.voting_power + voting_power;
            if (lock_end_time > voter_info.lock_end_time) {
                voter_info.lock_end_time = lock_end_time;
            };
        } else {
            let voter_info = VoterInfo {
                staked_amount: amount,
                voting_power,
                lock_end_time,
                delegation_target: option::none(),
                total_votes_cast: 0,
            };
            table::add(&mut governance.voters, sender, voter_info);
        };

        // Create staking position
        let position = StakingPosition {
            id: object::new(ctx),
            owner: sender,
            amount,
            lock_end_time,
            voting_power_multiplier: multiplier,
            created_at: current_time,
        };

        // Update governance totals
        governance.total_staked = governance.total_staked + amount;
        governance.total_voting_power = governance.total_voting_power + voting_power;

        // Store tokens in treasury
        balance::join(&mut governance.treasury_balance, coin::into_balance(tokens));

        event::emit(TokensStaked {
            staker: sender,
            amount,
            lock_period: lock_period_months,
            voting_power,
        });

        transfer::transfer(position, sender);
    }

    // Unstake tokens (after lock period)
    public entry fun unstake_tokens(
        governance: &mut GovernanceRegistry,
        position: StakingPosition,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time >= position.lock_end_time, E_VOTING_PERIOD_ENDED);
        assert!(position.owner == tx_context::sender(ctx), E_UNAUTHORIZED);

        let sender = tx_context::sender(ctx);
        let amount = position.amount;
        let voting_power = (amount * position.voting_power_multiplier) / 1000;

        // Update voter info
        let voter_info = table::borrow_mut(&mut governance.voters, sender);
        voter_info.staked_amount = voter_info.staked_amount - amount;
        voter_info.voting_power = voter_info.voting_power - voting_power;

        // Update governance totals
        governance.total_staked = governance.total_staked - amount;
        governance.total_voting_power = governance.total_voting_power - voting_power;

        // Return tokens to user
        let tokens = coin::take(&mut governance.treasury_balance, amount, ctx);
        transfer::public_transfer(tokens, sender);

        event::emit(TokensUnstaked {
            staker: sender,
            amount,
            voting_power_lost: voting_power,
        });

        // Destroy position
        let StakingPosition { 
            id, 
            owner: _, 
            amount: _, 
            lock_end_time: _, 
            voting_power_multiplier: _, 
            created_at: _ 
        } = position;
        object::delete(id);
    }

    // Create governance proposal
    public entry fun create_proposal(
        governance: &mut GovernanceRegistry,
        title: vector<u8>,
        description: vector<u8>,
        proposal_type: u8,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        
        // Check if sender has enough voting power
        assert!(table::contains(&governance.voters, sender), E_INSUFFICIENT_VOTING_POWER);
        let voter_info = table::borrow(&governance.voters, sender);
        assert!(voter_info.voting_power >= MIN_PROPOSAL_THRESHOLD, E_INSUFFICIENT_VOTING_POWER);

        let current_time = clock::timestamp_ms(clock);
        let proposal_id = governance.proposal_count;
        governance.proposal_count = governance.proposal_count + 1;

        let proposal = Proposal {
            id: object::new(ctx),
            proposal_id,
            proposer: sender,
            title: string::utf8(title),
            description: string::utf8(description),
            proposal_type,
            target_contract: option::none(),
            function_name: option::none(),
            parameters: bag::new(ctx),
            voting_start: current_time,
            voting_end: current_time + VOTING_PERIOD,
            execution_time: current_time + VOTING_PERIOD + EXECUTION_DELAY,
            yes_votes: 0,
            no_votes: 0,
            total_voting_power_snapshot: governance.total_voting_power,
            status: 0, // active
            voters: table::new(ctx),
        };

        let proposal_address = object::uid_to_address(&proposal.id);
        table::add(&mut governance.proposals, proposal_id, proposal_address);

        event::emit(ProposalCreated {
            proposal_id,
            proposer: sender,
            title: proposal.title,
            proposal_type,
            voting_end: proposal.voting_end,
        });

        transfer::share_object(proposal);
    }

    // Cast vote on proposal
    public entry fun vote(
        governance: &GovernanceRegistry,
        proposal: &mut Proposal,
        vote_yes: bool,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        let sender = tx_context::sender(ctx);

        // Validate voting conditions
        assert!(proposal.status == 0, E_PROPOSAL_NOT_ACTIVE);
        assert!(current_time <= proposal.voting_end, E_VOTING_PERIOD_ENDED);
        assert!(!table::contains(&proposal.voters, sender), E_ALREADY_VOTED);
        assert!(table::contains(&governance.voters, sender), E_INSUFFICIENT_VOTING_POWER);

        let voter_info = table::borrow(&governance.voters, sender);
        let voting_power = voter_info.voting_power;
        assert!(voting_power > 0, E_INSUFFICIENT_VOTING_POWER);

        // Record vote
        table::add(&mut proposal.voters, sender, true);
        
        if (vote_yes) {
            proposal.yes_votes = proposal.yes_votes + voting_power;
        } else {
            proposal.no_votes = proposal.no_votes + voting_power;
        };

        // Create vote record
        let vote_record = Vote {
            id: object::new(ctx),
            proposal_id: proposal.proposal_id,
            voter: sender,
            vote: vote_yes,
            voting_power,
            timestamp: current_time,
        };

        event::emit(VoteCast {
            proposal_id: proposal.proposal_id,
            voter: sender,
            vote: vote_yes,
            voting_power,
        });

        transfer::transfer(vote_record, sender);
    }

    // Execute passed proposal
    public entry fun execute_proposal(
        governance: &mut GovernanceRegistry,
        proposal: &mut Proposal,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        
        // Check if proposal can be executed
        assert!(current_time >= proposal.execution_time, E_VOTING_PERIOD_ENDED);
        assert!(current_time <= proposal.execution_time + EXECUTION_WINDOW, E_EXECUTION_WINDOW_EXPIRED);
        assert!(proposal.status == 0, E_PROPOSAL_NOT_ACTIVE);

        // Check if proposal passed
        let total_votes = proposal.yes_votes + proposal.no_votes;
        let quorum_met = (total_votes * 10000) / proposal.total_voting_power_snapshot >= QUORUM_THRESHOLD;
        let majority_reached = proposal.yes_votes * 10000 / total_votes >= PASSING_THRESHOLD;

        if (quorum_met && majority_reached) {
            proposal.status = 1; // passed
            
            // Execute proposal based on type
            let execution_successful = execute_proposal_action(governance, proposal, ctx);
            
            if (execution_successful) {
                proposal.status = 3; // executed
            };

            event::emit(ProposalExecuted {
                proposal_id: proposal.proposal_id,
                executor: tx_context::sender(ctx),
                execution_successful,
            });
        } else {
            proposal.status = 2; // failed
        }
    }

    // Execute proposal action based on type
    fun execute_proposal_action(
        governance: &mut GovernanceRegistry,
        proposal: &Proposal,
        _ctx: &mut TxContext
    ): bool {
        if (proposal.proposal_type == PROPOSAL_TREASURY_SPEND) {
            // Treasury spending logic would go here
            true
        } else if (proposal.proposal_type == PROPOSAL_PARAMETER_CHANGE) {
            // Parameter change logic would go here
            true
        } else if (proposal.proposal_type == PROPOSAL_EMERGENCY) {
            // Emergency action logic
            governance.emergency_mode = true;
            true
        } else {
            false
        }
    }

    // Delegate voting power
    public entry fun delegate_votes(
        governance: &mut GovernanceRegistry,
        delegate: address,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(table::contains(&governance.voters, sender), E_INSUFFICIENT_VOTING_POWER);
        
        let voter_info = table::borrow_mut(&mut governance.voters, sender);
        let old_delegate = voter_info.delegation_target;
        voter_info.delegation_target = option::some(delegate);

        event::emit(DelegationChanged {
            delegator: sender,
            old_delegate,
            new_delegate: option::some(delegate),
            voting_power: voter_info.voting_power,
        });
    }

    // Remove delegation
    public entry fun remove_delegation(
        governance: &mut GovernanceRegistry,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(table::contains(&governance.voters, sender), E_INSUFFICIENT_VOTING_POWER);
        
        let voter_info = table::borrow_mut(&mut governance.voters, sender);
        let old_delegate = voter_info.delegation_target;
        voter_info.delegation_target = option::none();

        event::emit(DelegationChanged {
            delegator: sender,
            old_delegate,
            new_delegate: option::none(),
            voting_power: voter_info.voting_power,
        });
    }

    // Create treasury spending proposal
    public entry fun create_treasury_proposal(
        governance: &mut GovernanceRegistry,
        title: vector<u8>,
        description: vector<u8>,
        recipient: address,
        amount: u64,
        purpose: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(table::contains(&governance.voters, sender), E_INSUFFICIENT_VOTING_POWER);
        let voter_info = table::borrow(&governance.voters, sender);
        assert!(voter_info.voting_power >= MIN_PROPOSAL_THRESHOLD, E_INSUFFICIENT_VOTING_POWER);

        let current_time = clock::timestamp_ms(clock);
        let proposal_id = governance.proposal_count;
        governance.proposal_count = governance.proposal_count + 1;

        let treasury_proposal = TreasuryProposal {
            id: object::new(ctx),
            recipient,
            amount,
            token_type: string::utf8(b"GFS"),
            purpose: string::utf8(purpose),
        };

        let mut proposal = Proposal {
            id: object::new(ctx),
            proposal_id,
            proposer: sender,
            title: string::utf8(title),
            description: string::utf8(description),
            proposal_type: PROPOSAL_TREASURY_SPEND,
            target_contract: option::none(),
            function_name: option::none(),
            parameters: bag::new(ctx),
            voting_start: current_time,
            voting_end: current_time + VOTING_PERIOD,
            execution_time: current_time + VOTING_PERIOD + EXECUTION_DELAY,
            yes_votes: 0,
            no_votes: 0,
            total_voting_power_snapshot: governance.total_voting_power,
            status: 0,
            voters: table::new(ctx),
        };

        // Store treasury proposal data in parameters bag
        bag::add(&mut proposal.parameters, b"treasury_proposal", treasury_proposal);

        let proposal_address = object::uid_to_address(&proposal.id);
        table::add(&mut governance.proposals, proposal_id, proposal_address);

        event::emit(ProposalCreated {
            proposal_id,
            proposer: sender,
            title: proposal.title,
            proposal_type: PROPOSAL_TREASURY_SPEND,
            voting_end: proposal.voting_end,
        });

        transfer::share_object(proposal);
    }

    // Execute treasury spending
    public entry fun execute_treasury_spending(
        governance: &mut GovernanceRegistry,
        proposal: &mut Proposal,
        ctx: &mut TxContext
    ) {
        assert!(proposal.status == 1, E_PROPOSAL_NOT_PASSED); // Must be passed
        assert!(proposal.proposal_type == PROPOSAL_TREASURY_SPEND, E_INVALID_PROPOSAL_TYPE);
        
        if (bag::contains(&proposal.parameters, b"treasury_proposal")) {
            let treasury_proposal: &TreasuryProposal = bag::borrow(&proposal.parameters, b"treasury_proposal");
            
            // Check if treasury has enough balance
            assert!(balance::value(&governance.treasury_balance) >= treasury_proposal.amount, E_INSUFFICIENT_TOKENS);
            
            // Transfer tokens to recipient
            let tokens = coin::take(&mut governance.treasury_balance, treasury_proposal.amount, ctx);
            transfer::public_transfer(tokens, treasury_proposal.recipient);
            
            proposal.status = 3; // executed
        };
    }

    // Emergency pause/resume system
    public entry fun toggle_emergency_mode(
        governance: &mut GovernanceRegistry,
        ctx: &mut TxContext
    ) {
        assert!(governance.admin == tx_context::sender(ctx), E_UNAUTHORIZED);
        governance.emergency_mode = !governance.emergency_mode;
    }

    // Cancel proposal (emergency or admin only)
    public entry fun cancel_proposal(
        governance: &GovernanceRegistry,
        proposal: &mut Proposal,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(
            governance.admin == sender || 
            (governance.emergency_mode && proposal.proposer == sender),
            E_UNAUTHORIZED
        );
        
        proposal.status = 4; // cancelled
    }

    // Get delegated voting power
    public fun get_effective_voting_power(governance: &GovernanceRegistry, voter: address): u64 {
        if (!table::contains(&governance.voters, voter)) {
            return 0
        };
        
        let voter_info = table::borrow(&governance.voters, voter);
        let mut total_power = voter_info.voting_power;
        
        // Add delegated power (simplified - in production would iterate through all delegators)
        total_power
    }

    // Simplified batch vote helper function
    public fun calculate_batch_vote_power(
        governance: &GovernanceRegistry,
        voter: address,
        proposal_count: u64
    ): u64 {
        if (!table::contains(&governance.voters, voter)) {
            return 0
        };
        
        let voter_info = table::borrow(&governance.voters, voter);
        voter_info.voting_power * proposal_count
    }

    // Advanced proposal with custom parameters
    public entry fun create_parameter_change_proposal(
        governance: &mut GovernanceRegistry,
        title: vector<u8>,
        description: vector<u8>,
        parameter_name: vector<u8>,
        new_value: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(table::contains(&governance.voters, sender), E_INSUFFICIENT_VOTING_POWER);
        let voter_info = table::borrow(&governance.voters, sender);
        assert!(voter_info.voting_power >= MIN_PROPOSAL_THRESHOLD, E_INSUFFICIENT_VOTING_POWER);

        let current_time = clock::timestamp_ms(clock);
        let proposal_id = governance.proposal_count;
        governance.proposal_count = governance.proposal_count + 1;

        let mut proposal = Proposal {
            id: object::new(ctx),
            proposal_id,
            proposer: sender,
            title: string::utf8(title),
            description: string::utf8(description),
            proposal_type: PROPOSAL_PARAMETER_CHANGE,
            target_contract: option::none(),
            function_name: option::none(),
            parameters: bag::new(ctx),
            voting_start: current_time,
            voting_end: current_time + VOTING_PERIOD,
            execution_time: current_time + VOTING_PERIOD + EXECUTION_DELAY,
            yes_votes: 0,
            no_votes: 0,
            total_voting_power_snapshot: governance.total_voting_power,
            status: 0,
            voters: table::new(ctx),
        };

        // Store parameter change data
        bag::add(&mut proposal.parameters, b"parameter_name", string::utf8(parameter_name));
        bag::add(&mut proposal.parameters, b"new_value", new_value);

        let proposal_address = object::uid_to_address(&proposal.id);
        table::add(&mut governance.proposals, proposal_id, proposal_address);

        event::emit(ProposalCreated {
            proposal_id,
            proposer: sender,
            title: proposal.title,
            proposal_type: PROPOSAL_PARAMETER_CHANGE,
            voting_end: proposal.voting_end,
        });

        transfer::share_object(proposal);
    }

    // Get proposal details with parameters
    public fun get_proposal_details(proposal: &Proposal): (u64, address, String, String, u8, u64, u64, u64, u64, u8) {
        (
            proposal.proposal_id,
            proposal.proposer,
            proposal.title,
            proposal.description,
            proposal.proposal_type,
            proposal.voting_start,
            proposal.voting_end,
            proposal.yes_votes,
            proposal.no_votes,
            proposal.status
        )
    }

    // Get total supply of governance tokens
    public fun get_total_supply(governance: &GovernanceRegistry): u64 {
        coin::total_supply(&governance.treasury_cap)
    }

    // Check if user has voted on proposal
    public fun has_voted(proposal: &Proposal, voter: address): bool {
        table::contains(&proposal.voters, voter)
    }

    // View functions
    public fun get_voter_info(governance: &GovernanceRegistry, voter: address): (u64, u64, u64) {
        if (table::contains(&governance.voters, voter)) {
            let voter_info = table::borrow(&governance.voters, voter);
            (voter_info.staked_amount, voter_info.voting_power, voter_info.lock_end_time)
        } else {
            (0, 0, 0)
        }
    }

    public fun get_proposal_status(proposal: &Proposal): (u64, u64, u64, u8) {
        (proposal.yes_votes, proposal.no_votes, proposal.total_voting_power_snapshot, proposal.status)
    }

    public fun get_governance_stats(governance: &GovernanceRegistry): (u64, u64, u64, bool) {
        (governance.total_staked, governance.total_voting_power, governance.proposal_count, governance.emergency_mode)
    }

    // Calculate voting results
    public fun calculate_voting_results(proposal: &Proposal): (bool, bool, u64) {
        let total_votes = proposal.yes_votes + proposal.no_votes;
        let quorum_met = (total_votes * 10000) / proposal.total_voting_power_snapshot >= QUORUM_THRESHOLD;
        let majority_reached = if (total_votes > 0) {
            proposal.yes_votes * 10000 / total_votes >= PASSING_THRESHOLD
        } else {
            false
        };
        let participation_rate = (total_votes * 10000) / proposal.total_voting_power_snapshot;
        
        (quorum_met, majority_reached, participation_rate)
    }
}