module cebulion_coin::cebulion_coin {
    use sui::clock::Clock;
    use sui::coin::{Coin, TreasuryCap};
    use sui::coin_registry::{Self, CoinRegistry, MetadataCap};
    use std::string;

    const E_NOT_AUTHORIZED: u64 = 0;
    const E_PAUSED: u64 = 1;
    const E_INSUFFICIENT_RESERVE: u64 = 2;
    const PEG_SCALE: u64 = 1_000_000;

    /// One-Time Witness for using new_currency_with_otw
    public struct CEBULION_COIN has drop {}

    /// Shared governance object for PLN
    public struct GovernancePLN has key, store {
        id: sui::object::UID,
        treasury: TreasuryCap<CEBULION_COIN>,
        metadata_cap: MetadataCap<CEBULION_COIN>,
        owner: address,
        paused: bool,
        reference_rate: u64,
        fiat_reserve: u64,
    }

    public struct MintEvent has copy, drop, store {
        recipient: address,
        amount: u64,
        updated_reference_rate: u64,
    }

    public struct BurnEvent has copy, drop, store {
        caller: address,
        amount: u64,
    }

    public struct PegUpdateEvent has copy, drop, store {
        new_reference_rate: u64,
        timestamp_ms: u64,
    }

    public struct ReserveUpdateEvent has copy, drop, store {
        currency: vector<u8>,
        old_reserve: u64,
        new_reserve: u64,
        change: u64,
        timestamp_ms: u64,
    }

    fun init(witness: CEBULION_COIN, ctx: &mut sui::tx_context::TxContext) {
        let owner = sui::tx_context::sender(ctx);

        // Step 1: Create currency with OTW - returns (CurrencyInitializer, TreasuryCap)
        let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
            witness,
            6u8,
            string::utf8(b"PLNS"),
            string::utf8(b"Cebulion PLN"),
            string::utf8(b"PLN-pegged stablecoin collateralized off-chain by Cebulion."),
            string::utf8(b"https://github.com/jakubGodula/cebulion_coin/blob/main/imgs/PLNS.png?raw=true"),
            ctx,
        );

        // Step 2: Finalize - this returns MetadataCap and shares the Currency object
        let metadata_cap = coin_registry::finalize(initializer, ctx);

        // Create and share governance object
        let governance_pln = GovernancePLN {
            id: sui::object::new(ctx),
            treasury: treasury_cap,
            metadata_cap,
            owner,
            paused: false,
            reference_rate: PEG_SCALE,
            fiat_reserve: 0,
        };
        sui::transfer::public_share_object(governance_pln);
    }

    public fun owner_pln(governance: &GovernancePLN): address {
        governance.owner
    }

    public fun reference_rate_pln(governance: &GovernancePLN): u64 {
        governance.reference_rate
    }

    public fun fiat_reserve_pln(governance: &GovernancePLN): u64 {
        governance.fiat_reserve
    }

    public fun total_supply_pln(governance: &GovernancePLN): u64 {
        sui::coin::total_supply(&governance.treasury)
    }

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

    public fun withdraw_reserve_pln(
        governance: &mut GovernancePLN,
        clock: &Clock,
        amount: u64,
        ctx: &mut sui::tx_context::TxContext,
    ) {
        assert!(sui::tx_context::sender(ctx) == governance.owner, E_NOT_AUTHORIZED);
        let total_supply = sui::coin::total_supply(&governance.treasury);
        assert!(governance.fiat_reserve >= amount, E_INSUFFICIENT_RESERVE);
        assert!(governance.fiat_reserve - amount >= total_supply, E_INSUFFICIENT_RESERVE);
        let old_reserve = governance.fiat_reserve;
        governance.fiat_reserve = governance.fiat_reserve - amount;
        sui::event::emit(ReserveUpdateEvent {
            currency: b"PLN",
            old_reserve,
            new_reserve: governance.fiat_reserve,
            change: amount,
            timestamp_ms: sui::clock::timestamp_ms(clock),
        });
    }

    public fun update_owner_pln(
        governance: &mut GovernancePLN,
        new_owner: address,
        ctx: &mut sui::tx_context::TxContext,
    ) {
        assert!(sui::tx_context::sender(ctx) == governance.owner, E_NOT_AUTHORIZED);
        governance.owner = new_owner;
    }

    public fun pause_pln(governance: &mut GovernancePLN, ctx: &mut sui::tx_context::TxContext) {
        assert!(sui::tx_context::sender(ctx) == governance.owner, E_NOT_AUTHORIZED);
        governance.paused = true;
    }

    public fun resume_pln(governance: &mut GovernancePLN, ctx: &mut sui::tx_context::TxContext) {
        assert!(sui::tx_context::sender(ctx) == governance.owner, E_NOT_AUTHORIZED);
        governance.paused = false;
    }

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

    public fun mint_pln(
        governance: &mut GovernancePLN,
        amount: u64,
        recipient: address,
        ctx: &mut sui::tx_context::TxContext,
    ) {
        assert!(sui::tx_context::sender(ctx) == governance.owner, E_NOT_AUTHORIZED);
        assert!(!governance.paused, E_PAUSED);
        
        let total_supply = sui::coin::total_supply(&governance.treasury);
        assert!(governance.fiat_reserve >= total_supply + amount, E_INSUFFICIENT_RESERVE);
        
        governance.fiat_reserve = governance.fiat_reserve - amount;

        let coins = sui::coin::mint(&mut governance.treasury, amount, ctx);
        sui::event::emit(MintEvent {
            recipient,
            amount,
            updated_reference_rate: governance.reference_rate,
        });
        sui::transfer::public_transfer(coins, recipient);
    }

    public fun burn_pln(
        governance: &mut GovernancePLN,
        coins: Coin<CEBULION_COIN>,
        ctx: &mut sui::tx_context::TxContext,
    ) {
        assert!(sui::tx_context::sender(ctx) == governance.owner, E_NOT_AUTHORIZED);
        let amount = sui::coin::burn(&mut governance.treasury, coins);
        
        governance.fiat_reserve = governance.fiat_reserve + amount;
        
        sui::event::emit(BurnEvent {
            caller: sui::tx_context::sender(ctx),
            amount,
        });
    }
}
