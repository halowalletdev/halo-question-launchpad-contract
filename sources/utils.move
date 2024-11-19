module minter::utils {
    use std::error;
    use std::signer;
    use aptos_framework::timestamp;
    use std::string::{Self, String};
    use aptos_framework::event;
    use aptos_framework::aptos_account;
    use aptos_framework::coin;

    const EINSUFFICIENT_BALANCE: u64 = 2;
    #[event]
    struct CoinPaymentEvent<phantom CoinType> has drop, store {
        from: address,
        to: address,
        amount: u64,
        category: String
    }

    ///  --- now------------------current_end_time
    ///  --- now-------------------------------+single interval--->new_end_time
    ///      < ------------------------------- <= max interval -------------->
    public fun update_end_time(
        current_end_time: u64, single_extend_interval: u64, max_interval: u64
    ): u64 {
        let now_time: u64 = timestamp::now_seconds();
        if (now_time < current_end_time) {
            let delta: u64 = current_end_time - now_time; //>0
            if (delta + single_extend_interval < max_interval) {
                current_end_time + single_extend_interval
            } else {
                now_time + max_interval
            }
        } else { // now_time >= current_end_time: don't change
            current_end_time
        }
    }

 
    public fun pay_to<CoinType>(
        payer: &signer,
        to: address,
        amount: u64,
        category: String
    ) {
        let from: address = signer::address_of(payer);
        assert!(
            coin::balance<CoinType>(from) >= amount,
            error::invalid_state(EINSUFFICIENT_BALANCE)
        );
        aptos_account::transfer_coins<CoinType>(payer, to, amount);

        event::emit(
            CoinPaymentEvent<CoinType> { from, to, amount, category }
        );
    }

    #[view]
    public fun string2bytes(str: String): vector<u8> {
        *string::bytes(&str)
    }

    #[test_only]
    use aptos_framework::account::create_account_for_test;

    #[test_only]
    use aptos_framework::aptos_coin::{Self, AptosCoin};

    #[test(aptos = @0x1)]
    fun test_update_end_time(aptos: &signer) {
        timestamp::set_time_has_started_for_testing(aptos);
        let single_extend_interval = 30 * 60; // 30mins
        let max_interval = 72 * 60 * 60; // 72hours
        let now_time = timestamp::now_seconds();

        let new_end0 = update_end_time(now_time, single_extend_interval, max_interval);
        assert!(new_end0 == now_time, error::invalid_state(0));

        let new_end1 = update_end_time(
            now_time + 1000, single_extend_interval, max_interval
        );
        assert!(
            new_end1 == now_time + 1000 + single_extend_interval,
            error::invalid_state(1)
        );

        let new_end2 =
            update_end_time(now_time + 10000, single_extend_interval, max_interval);
        assert!(
            new_end2 == now_time + 10000 + single_extend_interval,
            error::invalid_state(2)
        );

        let new_end3 =
            update_end_time(
                now_time + max_interval - 1000,
                single_extend_interval,
                max_interval
            );
        assert!(new_end3 == max_interval, error::invalid_state(3));
        // unnormal -- will not exist
        let new_end4 =
            update_end_time(
                now_time + max_interval + 1000,
                single_extend_interval,
                max_interval
            );
        assert!(new_end4 == max_interval, error::invalid_state(4));

    }

    #[test(aptos = @0x1)]
    fun test_pay(aptos: &signer) {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos);
        let from: signer = create_account_for_test(@0x1001);
        let to_addr = @0x2001;
        // add initial coin
        coin::register<AptosCoin>(&from);
        let coins = coin::mint(1000, &mint_cap);
        coin::deposit(signer::address_of(&from), coins);
        // from->to 50:
        pay_to<AptosCoin>(&from, to_addr, 50, string::utf8(b"test"));
        // result:
        assert!(coin::balance<AptosCoin>(signer::address_of(&from)) == 950, 1);
        assert!(coin::balance<AptosCoin>(to_addr) == 50, 2);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(aptos = @0x1)]
    #[expected_failure(abort_code = 196610, location = Self)]
    fun test_pay_insufficient(aptos: &signer) {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos);
        let from: signer = create_account_for_test(@0x1001);
        let to_addr = @0x2001;
        // add initial coin
        coin::register<AptosCoin>(&from);
        let coins = coin::mint(1000, &mint_cap);
        coin::deposit(signer::address_of(&from), coins);
        // from->to 50000:
        pay_to<AptosCoin>(&from, to_addr, 50000, string::utf8(b"test"));
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }
}
