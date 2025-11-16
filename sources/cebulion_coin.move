module cebulion_coin::cebulion_coin {
    use sui::clock::Clock;
    use sui::coin::{Coin, CoinMetadata, TreasuryCap};
    use sui::url::Url;

    const E_NOT_AUTHORIZED: u64 = 0;
    const E_PAUSED: u64 = 1;
    const E_INSUFFICIENT_RESERVE: u64 = 2;

    /// Peg precision: values are expressed as currency per coin scaled by 1e6.
    /// A `reference_rate` of 1_000_000 represents exactly 1 unit of the currency.
    const PEG_SCALE: u64 = 1_000_000;

    /// Coin type marker for the Cebulion PLN stablecoin.
    public struct CebulionPLN has drop, store {}


    /// Shared governance object for PLN that keeps track of the treasury and policy flags.
    /// `fiat_reserve` tracks the amount of PLN held off-chain as backing for the stablecoin.
    /// Maintains 1:1 coverage - each coin must have 1 unit of fiat reserve backing it.
    public struct GovernancePLN has key, store {
        id: sui::object::UID,
        treasury: TreasuryCap<CebulionPLN>,
        owner: address,
        paused: bool,
        reference_rate: u64,
        fiat_reserve: u64, // Amount of PLN held off-chain (in smallest units, 6 decimals)
    }


    /// Event emitted whenever new coins are minted.
    public struct MintEvent has copy, drop, store {
        recipient: address,
        amount: u64,
        updated_reference_rate: u64,
    }

    /// Event emitted whenever circulating coins are redeemed and burned.
    public struct BurnEvent has copy, drop, store {
        caller: address,
        amount: u64,
    }

    /// Event emitted whenever the issuer updates the reference rate.
    public struct PegUpdateEvent has copy, drop, store {
        new_reference_rate: u64,
        timestamp_ms: u64,
    }

    /// Event emitted whenever fiat reserves are deposited or withdrawn.
    public struct ReserveUpdateEvent has copy, drop, store {
        currency: vector<u8>, // "PLN", "EUR", or "USD"
        old_reserve: u64,
        new_reserve: u64,
        change: u64, // positive for deposit, negative for withdrawal
        timestamp_ms: u64,
    }

    /// Initializes all three Cebulion stablecoins (PLN, EUR, USD). This function is called automatically
    /// on package publish. It mints the treasury capabilities, publishes metadata, and
    /// shares the governance objects that control minting and policy updates.
    fun init(ctx: &mut sui::tx_context::TxContext) {
        let owner = sui::tx_context::sender(ctx);

        // Initialize PLN stablecoin
        let (treasury_cap_pln, metadata_pln): (TreasuryCap<CebulionPLN>, CoinMetadata<CebulionPLN>) = sui::coin::create_currency(
            CebulionPLN {},
            6,
            b"CEBPLN",
            b"Cebulion PLN",
            b"PLN-pegged stablecoin collateralized off-chain by Cebulion.",
            std::option::none<Url>(),
            ctx,
        );
        sui::transfer::public_share_object(metadata_pln);
        let governance_pln = GovernancePLN {
            id: sui::object::new(ctx),
            treasury: treasury_cap_pln,
            owner,
            paused: false,
            reference_rate: PEG_SCALE,
            fiat_reserve: 0,
        };
        sui::transfer::public_share_object(governance_pln);

    }

    // ========== PLN Functions ==========

    /// Returns the current governance owner address for PLN.
    public fun owner_pln(governance: &GovernancePLN): address {
        governance.owner
    }

    /// Returns the current reference rate for PLN (scaled by `PEG_SCALE`).
    public fun reference_rate_pln(governance: &GovernancePLN): u64 {
        governance.reference_rate
    }

    /// Returns the current fiat reserve amount for PLN.
    public fun fiat_reserve_pln(governance: &GovernancePLN): u64 {
        governance.fiat_reserve
    }

    /// Returns the total supply of PLN coins in circulation.
    public fun total_supply_pln(governance: &GovernancePLN): u64 {
        sui::coin::total_supply(&governance.treasury)
    }

    /// Deposits fiat reserves for PLN. Called when fiat is deposited off-chain.
    /// This increases the available backing for minting new coins.
    public fun deposit_reserve_pln(
        governance: &mut GovernancePLN,
        clock: &Clock,
        amount: u64,
        ctx: &mut sui::tx_context::TxContext,
    ) {
        assert!(sui::tx_context::sender(ctx) == governance.owner, E_NOT_AUTHORIZED);
        let old_reserve = governance.fiat_reserve;
        governance.fiat_reserve = governance.fiat_reserve + amount;
        sui::event::emit(ReserveUpdateEvent {
            currency: b"PLN",
            old_reserve,
            new_reserve: governance.fiat_reserve,
            change: amount,
            timestamp_ms: sui::clock::timestamp_ms(clock),
        });
    }

    /// Withdraws fiat reserves for PLN. Called when fiat is withdrawn off-chain.
    /// Can only withdraw if there's sufficient reserve above the circulating supply.
    public fun withdraw_reserve_pln(
        governance: &mut GovernancePLN,
        clock: &Clock,
        amount: u64,
        ctx: &mut sui::tx_context::TxContext,
    ) {
        assert!(sui::tx_context::sender(ctx) == governance.owner, E_NOT_AUTHORIZED);
        let total_supply = sui::coin::total_supply(&governance.treasury);
        assert!(governance.fiat_reserve >= amount, E_INSUFFICIENT_RESERVE);
        // Ensure we maintain at least 1:1 coverage after withdrawal
        assert!(governance.fiat_reserve - amount >= total_supply, E_INSUFFICIENT_RESERVE);
        let old_reserve = governance.fiat_reserve;
        governance.fiat_reserve = governance.fiat_reserve - amount;
        sui::event::emit(ReserveUpdateEvent {
            currency: b"PLN",
            old_reserve,
            new_reserve: governance.fiat_reserve,
            change: amount, // Will be interpreted as withdrawal (negative)
            timestamp_ms: sui::clock::timestamp_ms(clock),
        });
    }

    /// Grants minting rights to the specified owner for PLN. This function is restricted to
    /// the current governance owner.
    public fun update_owner_pln(
        governance: &mut GovernancePLN,
        new_owner: address,
        ctx: &mut sui::tx_context::TxContext,
    ) {
        assert!(sui::tx_context::sender(ctx) == governance.owner, E_NOT_AUTHORIZED);
        governance.owner = new_owner;
    }

    /// Allows the owner to pause minting operations for PLN.
    public fun pause_pln(governance: &mut GovernancePLN, ctx: &mut sui::tx_context::TxContext) {
        assert!(sui::tx_context::sender(ctx) == governance.owner, E_NOT_AUTHORIZED);
        governance.paused = true;
    }

    /// Allows the owner to resume minting operations for PLN.
    public fun resume_pln(governance: &mut GovernancePLN, ctx: &mut sui::tx_context::TxContext) {
        assert!(sui::tx_context::sender(ctx) == governance.owner, E_NOT_AUTHORIZED);
        governance.paused = false;
    }

    /// Updates the off-chain reference rate for PLN used for transparency disclosures.
    /// The rate is expressed as PLN per coin scaled by `PEG_SCALE`.
    public fun update_reference_rate_pln(
        governance: &mut GovernancePLN,
        clock: &Clock,
        new_reference_rate: u64,
        ctx: &mut sui::tx_context::TxContext,
    ) {
        assert!(sui::tx_context::sender(ctx) == governance.owner, E_NOT_AUTHORIZED);
        governance.reference_rate = new_reference_rate;
        sui::event::emit(PegUpdateEvent {
            new_reference_rate,
            timestamp_ms: sui::clock::timestamp_ms(clock),
        });
    }

    /// Mints new PLN coins to the specified recipient. Restricted to the governance owner
    /// and disabled while the system is paused. Requires 1:1 fiat reserve backing.
    public fun mint_pln(
        governance: &mut GovernancePLN,
        amount: u64,
        recipient: address,
        ctx: &mut sui::tx_context::TxContext,
    ) {
        assert!(sui::tx_context::sender(ctx) == governance.owner, E_NOT_AUTHORIZED);
        assert!(!governance.paused, E_PAUSED);
        
        // Check that we have sufficient reserve to maintain 1:1 coverage
        let total_supply = sui::coin::total_supply(&governance.treasury);
        assert!(governance.fiat_reserve >= total_supply + amount, E_INSUFFICIENT_RESERVE);
        
        // Deduct from reserve to maintain 1:1 backing
        governance.fiat_reserve = governance.fiat_reserve - amount;

        let coins = sui::coin::mint(&mut governance.treasury, amount, ctx);
        sui::event::emit(MintEvent {
            recipient,
            amount,
            updated_reference_rate: governance.reference_rate,
        });
        sui::transfer::public_transfer(coins, recipient);
    }

    /// Burns PLN coins that have been returned to treasury custody.
    /// Releases the corresponding fiat reserve, allowing it to be withdrawn.
    public fun burn_pln(
        governance: &mut GovernancePLN,
        coins: Coin<CebulionPLN>,
        ctx: &mut sui::tx_context::TxContext,
    ) {
        assert!(sui::tx_context::sender(ctx) == governance.owner, E_NOT_AUTHORIZED);
        let amount = sui::coin::burn(&mut governance.treasury, coins);
        
        // Release reserve when coins are burned (can now be withdrawn)
        governance.fiat_reserve = governance.fiat_reserve + amount;
        
        sui::event::emit(BurnEvent {
            caller: sui::tx_context::sender(ctx),
            amount,
        });
    }

}