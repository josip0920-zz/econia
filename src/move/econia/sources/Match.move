/// Matching engine functionality, integrating user-side and book-side
/// modules
///
/// # Sides
///
/// In the case of a market sell (which fills against bids on the book),
/// it is possible to verify that the submitting user has enough
/// collateral, in the form of base coin subunits, ahead of time,
/// because they pre-specify the amount of base coins they are trying to
/// sell. They will receive an unspecified amount of quote coins in
/// return, but it does not matter that this amount is unknown because
/// the value simply gets added to their collateral.
///
/// In the case of a market buy (which fills against asks on the book),
/// however, it is not possible to verify that the submitting user has
/// enough collateral, in the form of quote coin subunits, ahead of
/// time: the amount of quote coins required to complete the market buy
/// depends on the size and price of each ask position on the book,
/// hence a user must pre-specify how many quote coin subunits they are
/// willing to pay when submitting their order.
///
/// # Terminology
/// * An "incoming order" is the market order filling against positions
///   on the book
/// * A "target position" is the position on the book being filled
///   during one filling iteration of traversal along the tree
/// * A "partial fill" is one where the target position still has a
///   nonzero size after the fill
/// * An "exact fill" is one where the target position and the incoming
///   order require the same number of base coin parcels to fill
/// * A "complete fill" is one where the incoming order is completely
///   filled against the target position, but traversal must continue
///   because the incoming order still has not been filled
///
/// # Testing
///
/// Test-only constants and functions are used to construct a test
/// market with simulated positions. During testing, the "incoming
/// market order" fills against the "target position" during iterated
/// traversal, with markets constructed so that for both ask and bid
/// trees, user 1's position is filled before user 2's, which is filled
/// before user 3's. Hence, the following tests exercise logic at
/// sequential milestones along the process of clearing out the book,
/// whether via a market buy (filling against asks) or a market sell
/// (filling against bids):
/// * `ask_partial_1()`
/// * `bid_exact_1()`
/// * `bid_partial_2()`
/// * `ask_exact_2()`
/// * `ask_partial_3()`
/// * `bid_exact_3()`
/// * `ask_clear_book()`
///
/// As described in [sides](#sides), in the case of a market buy
/// (filling against asks on the book), the following tests exercise
/// logic at sequential milestones of exhausting available quote coins
/// along the process of clearing out the book:
/// * `buy_exhaust_immediately()`
/// * `buy_exhaust_partial_1_complete_requested()`
/// * `buy_exhaust_exact_1_complete_requested()`
/// * `buy_exhaust_partial_2_exact_requested()`
/// * `buy_exhaust_exact_2_exact_requested()`
/// * `buy_exhaust_partial_3_larger_partial_requested()`
/// * `buy_exhaust_exact_3_complete_requested()`
///
/// ---
///
module Econia::Match {

    // Uses >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    use aptos_framework::coin::{
        is_account_registered as exists_coin_store,
        register as register_coin_store
    };

    use Econia::Book::{
        exists_book,
        cancel_position,
        FriendCap as BookCap,
        n_asks,
        n_bids,
        scale_factor,
        refresh_extreme_order_id,
        traverse_init_fill,
        traverse_pop_fill
    };

    use Econia::Caps::{
        book_f_c as book_cap,
        orders_f_c as orders_cap
    };

    use Econia::ID::{
        price as id_p
    };

    use Econia::Orders::{
        FriendCap as OrdersCap,
        scale_factor as orders_scale_factor
    };

    use Econia::User::{
        exists_o_c,
        exists_sequence_counter,
        exists_o_c as exists_order_collateral,
        dec_available_collateral,
        deposit_internal as collateral_deposit,
        get_available_collateral,
        init_containers,
        init_user,
        process_fill,
        update_s_c as update_user_seq_counter,
        withdraw_internal as collateral_withdraw
    };

    use std::signer::{
        address_of
    };

    // Uses <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Test-only uses >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[test_only]
    use aptos_framework::account::{
        create_account,
        increment_sequence_number
    };

    #[test_only]
    use aptos_framework::coin::{
        balance as coin_store_balance
    };

    #[test_only]
    use Econia::Book::{
        check_extreme_order_id,
        check_position,
        has_position
    };

    #[test_only]
    use Econia::ID::{
        id_a,
        id_b
    };

    #[test_only]
    use Econia::Orders::{
        check_order,
        has_order
    };

    #[test_only]
    use Econia::Registry::{
        BCT,
        E1,
        mint_bct_to,
        mint_qct_to,
        QCT,
    };

    #[test_only]
    use Econia::User::{
        check_collateral,
        init_funded_user,
        init_test_scaled_market_funded_user,
        submit_ask,
        submit_bid
    };

    // Test-only uses <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Error codes >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// When no corresponding market registered
    const E_NO_MARKET: u64 = 0;
    /// When user does not have order collateral container
    const E_NO_O_C: u64 = 1;
    /// When not enough collateral for an operation
    const E_NOT_ENOUGH_COLLATERAL: u64 = 2;
    // When an order is placed without a size
    const E_SIZE_0: u64 = 3;
    // When a market buy is placed with 0 allocated quote coins to spend
    const E_QUOTE_SPEND_0: u64 = 4;

    // Error codes <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Constants >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Ask flag
    const ASK: bool = true;
    /// Bid flag
    const BID: bool = false;
    /// Flag for submitting a market buy
    const BUY: bool = true;
    /// Flag for submitting a market sell
    const SELL: bool = false;

    // Constants <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Test-only constants >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[test_only]
    const USER_0_START_BASE: u64 = 1000;
    #[test_only]
    const USER_1_START_BASE: u64 = 2000;
    #[test_only]
    const USER_2_START_BASE: u64 = 3000;
    #[test_only]
    const USER_3_START_BASE: u64 = 4000;
    #[test_only]
    const USER_0_START_QUOTE: u64 = 1500;
    #[test_only]
    const USER_1_START_QUOTE: u64 = 2500;
    #[test_only]
    const USER_2_START_QUOTE: u64 = 3500;
    #[test_only]
    const USER_3_START_QUOTE: u64 = 4500;
    #[test_only]
    const SCALE_FACTOR: u64 = 10;
    #[test_only]
    const USER_1_ASK_PRICE: u64 = 10;
    #[test_only]
    const USER_2_ASK_PRICE: u64 = 11;
    #[test_only]
    const USER_3_ASK_PRICE: u64 = 12;
    #[test_only]
    const USER_1_ASK_SIZE: u64 = 9;
    #[test_only]
    const USER_2_ASK_SIZE: u64 = 8;
    #[test_only]
    const USER_3_ASK_SIZE: u64 = 7;
    #[test_only]
    const USER_1_BID_SIZE: u64 = 3;
    #[test_only]
    const USER_2_BID_SIZE: u64 = 4;
    #[test_only]
    const USER_3_BID_SIZE: u64 = 5;
    #[test_only]
    const USER_1_BID_PRICE: u64 = 5;
    #[test_only]
    const USER_2_BID_PRICE: u64 = 4;
    #[test_only]
    const USER_3_BID_PRICE: u64 = 3;
    #[test_only]
    const USER_1_VER_NUM: u64 = 1;
    #[test_only]
    const USER_2_VER_NUM: u64 = 2;
    #[test_only]
    const USER_3_VER_NUM: u64 = 3;
    #[test_only]
    /// Default value for maximum bid order ID
    const MAX_BID_DEFAULT: u128 = 0;
    #[test_only]
    /// Default value for minimum ask order ID
    const MIN_ASK_DEFAULT: u128 = 0xffffffffffffffffffffffffffffffff;

    // Test-only constants <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Public entry functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[cmd(desc=b"Submit market order to buy B with Q")]
    /// Wrapped call to `submit_market_order()` for side `BUY`
    public entry fun submit_market_buy<B, Q, E>(
        user: &signer,
        host: address,
        requested_size: u64,
        max_quote_to_spend: u64
    ) {
        submit_market_order<B, Q, E>(
            user, host, BUY, requested_size, max_quote_to_spend);
        // Update user sequence counter
        update_user_seq_counter(user, &orders_cap());
    }

    #[cmd(desc=b"Submit market order to sell B to Q")]
    /// Wrapped call to `submit_market_order()` for side `SELL`,
    public entry fun submit_market_sell<B, Q, E>(
        user: &signer,
        host: address,
        requested_size: u64,
    ) {
        submit_market_order<B, Q, E>(user, host, SELL, requested_size, 0);
        // Update user sequence counter
        update_user_seq_counter(user, &orders_cap());
    }

    /// Submit either a market `BUY` or `SELL`, initializing account
    /// resources as needed, depositing as needed, and withdrawing all
    /// available collateral after the swap. Deposits required amounts
    /// from `user`'s `AptosFramework` coin stores into their Econia
    /// order collateral cointainer before the swap, executes the swap,
    /// then withdraws all order collateral back to coin stores.
    ///
    /// # Parameters
    /// * `user`: User performing swap
    /// * `host`: Market host
    /// * `side`: `BUY` or `SELL`
    /// * `requested_size`: Requested number of base coin parcels to be
    //    filled
    /// * `max_quote_to_spend`: Maximum number of quote coins that can
    ///   be spent in the case of a market buy (unused in case of a
    ///   market sell)
    /// * `orders_cap`: Mutable reference to `OrdersCap`
    ///
    /// # Considerations
    /// * Designed to be a private function, but calls public entry
    ///   functions, so has to be itself a public entry function. Hence
    ///   the `&OrdersCap` to prevent SDKs from calling this version,
    ///   ensuring they only call wrapped versions
    public entry fun swap<B, Q, E>(
        user: &signer,
        host: address,
        side: bool,
        requested_size: u64,
        max_quote_to_spend: u64,
        orders_cap: &OrdersCap
    ) {
        let user_addr = address_of(user); // Get user address
        // Initialize user if they do not have a sequence counter
        if (!exists_sequence_counter(user_addr, orders_cap)) init_user(user);
        // Initialize containers for given market if user has none
        if (!exists_order_collateral<B, Q ,E>(user_addr, orders_cap))
            init_containers<B, Q, E>(user);
        // If user does not have base coin store, register one
        if (!exists_coin_store<B>(user_addr)) register_coin_store<B>(user);
        // If user does not have quote coin store, register one
        if (!exists_coin_store<Q>(user_addr)) register_coin_store<Q>(user);
        // If a market buy, deposit max quote coins willing to spend
        if (side == BUY) { // If a market buy
            // Deposit max amount of quote coins willing to spend
            collateral_deposit<B, Q, E>(
                user, 0, max_quote_to_spend, orders_cap);
        } else { // If a market sell
            // Calculate base coin subunits needed for order
            let base_coins_needed = requested_size *
                orders_scale_factor<B, Q, E>(user_addr, orders_cap);
            // Deposit base coins as collateral
            collateral_deposit<B, Q, E>(
                user, base_coins_needed, 0, orders_cap);
        };
        // Submit a market order with corresponding values
        submit_market_order<B, Q, E>(user, host, side, requested_size,
            max_quote_to_spend);
        // Determine amount of availble collateral user has
        let (base_collateral, quote_collateral) =
            get_available_collateral<B, Q, E>(user_addr, orders_cap);
        // Withdraw all available collateral back to user's coin stores
        collateral_withdraw<B, Q, E>(
            user, base_collateral, quote_collateral, orders_cap);
    }

    #[cmd(desc=b"Swap B to Q")]
    /// Wrapped call to `swap()` for `BUY`
    public entry fun swap_buy<B, Q, E>(
        user: &signer,
        host: address,
        requested_size: u64,
        max_quote_to_spend: u64,
    ) {
        swap<B, Q, E>(user, host, BUY, requested_size, max_quote_to_spend,
            &orders_cap())
    }

    #[cmd(desc=b"Swap Q to B")]
    /// Wrapped call to `swap()` for `SELL`
    public entry fun swap_sell<B, Q, E>(
        user: &signer,
        host: address,
        requested_size: u64,
    ) {
        swap<B, Q, E>(user, host, SELL, requested_size, 0, &orders_cap())
    }

    // Public entry functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Private functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Fill a market order against the book as much as possible,
    /// returning when there is no liquidity left or when order is
    /// completely filled
    ///
    /// # Parameters
    /// * `host` Host of corresponding order book
    /// * `addr`: Address of user placing market order
    /// * `side`: `ASK` or `BID`, denoting the side on the order book
    ///   which should be filled against. If `ASK`, user is submitting
    ///   a market buy, if `BID`, user is submitting a market sell
    /// * `requested_size`: Base coin parcels to be filled
    /// * `quote_available`: Quote coin parcels available for filling if
    ///   filling against asks
    /// * `book_cap`: Immutable reference to `Econia::Book:FriendCap`
    ///
    /// # Terminology
    /// * "Incoming order" is the market order being matched against
    ///   the order book
    /// * "Target position" is the position on the book for each stage
    ///   of iterated traversal
    ///
    /// # Returns
    /// * `u64`: Amount of base coin subunits filled
    /// * `u64`: Amount of quote coin subunits filled
    ///
    /// # Assumptions
    /// * Order book has been properly initialized at host address
    /// * `size` is nonzero
    fun fill_market_order<B, Q, E>(
        host: address,
        addr: address,
        side: bool,
        requested_size: u64,
        quote_available: u64,
        book_cap: &BookCap
    ): (
        u64,
        u64,
    ) {
        // Get number of positions on corresponding order book side
        let n_positions = if (side == ASK) n_asks<B, Q, E>(host, book_cap)
            else n_bids<B, Q, E>(host, book_cap);
        // Return no fills if no positions on book
        if (n_positions == 0) return (0, 0);
        // Get scale factor of corresponding order book
        let scale_factor = scale_factor<B, Q, E>(host, book_cap);
        // Initialize counters for base coin parcels and quote coin
        // subunits filled
        let (base_parcels_filled, quote_coins_filled) = (0, 0);
        // Initialize traversal, storing ID of target position, address
        // of user holding it, the parent field of corresponding tree
        // node, child index of corresponding node, amount filled, if an
        // exact match between incoming order and target position, and
        // if the incoming order has insufficient quote coins in case of
        // an ask
        let (target_id, target_addr, target_p_f, target_c_i, filled, exact,
             insufficient_quote) =
            traverse_init_fill<B, Q, E>(
                host, addr, side, requested_size, quote_available, book_cap);
        loop { // Begin traversal loop
            // Update counter for number of base parcels filled
            base_parcels_filled = base_parcels_filled + filled;
            // Calculate number of quote coins just filled
            let quote_coins_just_filled = id_p(target_id) * filled;
            // Update counter for number of quote coins filled
            quote_coins_filled = quote_coins_filled + quote_coins_just_filled;
            // If filling against asks, update counter for quote coins
            // still available for filling
            if (side == ASK) quote_available =
                quote_available - quote_coins_just_filled;
            // Decrement requested size left to match
            requested_size = requested_size - filled;
            // Determine if target position completely filled
            let complete = ((exact || requested_size > 0) &&
                            !insufficient_quote);
            // Route funds between counterparties, update open orders
            process_fill<B, Q, E>(target_addr, addr, side, target_id, filled,
                                  scale_factor, complete);
            // If incoming order unfilled and can traverse
            if (requested_size > 0 && n_positions > 1 && !insufficient_quote) {
                // Traverse pop fill to next position
                (target_id, target_addr, target_p_f, target_c_i, filled, exact,
                    insufficient_quote)
                    = traverse_pop_fill<B, Q, E>(
                        host, addr, side, requested_size, quote_available,
                        n_positions, target_id, target_p_f, target_c_i,
                        book_cap);
                // Decrement count of positions on book for given side
                n_positions = n_positions - 1;
            } else { // If should not continue iterated traverse fill
                // Determine if a partial target fill was made
                let partial_target_fill =
                    (requested_size == 0 && !exact) || insufficient_quote;
                // If anything other than a partial target fill made
                if (!partial_target_fill) {
                    // Cancel target position
                    cancel_position<B, Q, E>(host, side, target_id, book_cap);
                };
                // Refresh the max bid/min ask ID for the order book
                refresh_extreme_order_id<B, Q, E>(host, side, book_cap);
                break // Break out of iterated traversal loop
            };
        };
        // Return base coin subunits and quote coin subunits filled
        (base_parcels_filled * scale_factor, quote_coins_filled)
    }

    /// Submit market order for market `<B, Q, E>`, filling as much
    /// as possible against the book
    ///
    /// # Parameters
    /// * `user`: User submitting a limit order
    /// * `host`: The market host (See `Econia::Registry`)
    /// * `side`: `ASK` or `BID`
    /// * `requested_size`: Requested number of base coin parcels to be
    //    filled
    /// * `max_quote_to_spend`: Maximum number of quote coins that can
    ///   be spent in the case of a market buy (unused in case of a
    ///   market sell)
    ///
    /// # Abort conditions
    /// * If no such market exists at host address
    /// * If user does not have order collateral container for market
    /// * If user does not have enough collateral
    /// * If `requested_size` is 0
    ///
    /// # Assumptions
    /// * `requested_size` is nonzero
    fun submit_market_order<B, Q, E>(
        user: &signer,
        host: address,
        side: bool,
        requested_size: u64,
        max_quote_to_spend: u64
    ) {
        // Assert order has actual size
        assert!(requested_size > 0, E_SIZE_0);
        // If a market buy, assert willing to spend quote coins
        if (side == BUY) assert!(max_quote_to_spend > 0, E_QUOTE_SPEND_0);
        // Get book-side and open-orders side capabilities
        let (book_cap, orders_cap) = (book_cap(), orders_cap());
        // Assert market exists at given host address
        assert!(exists_book<B, Q, E>(host, &book_cap), E_NO_MARKET);
        let user_address = address_of(user); // Get user address
        // Assert user has order collateral container
        assert!(exists_o_c<B, Q, E>(user_address, &orders_cap), E_NO_O_C);
        // Get available collateral for user on given market
        let (base_available, quote_available) =
            get_available_collateral<B, Q, E>(user_address, &orders_cap);
        // If submitting a market buy (if filling against ask positions
        // on the order book)
        if (side == BUY) {
            // Assert user has enough quote coins to spend
            assert!(quote_available >= max_quote_to_spend,
                E_NOT_ENOUGH_COLLATERAL);
            // Fill a market order through the matching engine, storing
            // number of quote coins spent
            let (_, quote_coins_spent) = fill_market_order<B, Q, E>(
                host, user_address, ASK, requested_size, max_quote_to_spend,
                &book_cap());
            // Update count of available quote coins
            dec_available_collateral<B, Q, E>(
                user_address, 0, quote_coins_spent, &orders_cap);
        } else { // If submitting a market sell (filling against bids)
            // Get number of base coins required to execute market sell
            let base_coins_required = requested_size *
                orders_scale_factor<B, Q, E>(user_address, &orders_cap());
            // Assert user has enough available base coins to sell
            assert!(base_available >= base_coins_required,
                E_NOT_ENOUGH_COLLATERAL);
            // Fill a market order through the matching engine, storing
            // number of base coin subunits sold
            let (base_coins_sold, _) = fill_market_order<B, Q, E>(
                host, user_address, BID, requested_size, 0, &book_cap());
            // Update count of available base coins
            dec_available_collateral<B, Q, E>(
                user_address, base_coins_sold, 0, &orders_cap);
        }
    }

    // Private functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Test-only functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    #[test_only]
    /// Initialize all users for trading on the test market
    /// `<BCT, QCT, E1>` hosted by `econia`, then place limit orders
    /// for `user_1`, `user_2`, `user_3`, based on `side`, returning
    /// the order ID for each respective position
    public entry fun init_market(
        side: bool,
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ): (
        u128,
        u128,
        u128
    ) {
        // Initialize test market with scale exponent 1, fund all users
        init_test_scaled_market_funded_user<E1>(
            econia, user_0, USER_0_START_BASE, USER_0_START_QUOTE);
        init_funded_user<E1>(user_1, USER_1_START_BASE, USER_1_START_QUOTE);
        init_funded_user<E1>(user_2, USER_2_START_BASE, USER_2_START_QUOTE);
        init_funded_user<E1>(user_3, USER_3_START_BASE, USER_3_START_QUOTE);
        // Define user order prices and sizes based on market side
        let user_1_order_price = if (side == ASK)
            USER_1_ASK_PRICE else USER_1_BID_PRICE;
        let user_2_order_price = if (side == ASK)
            USER_2_ASK_PRICE else USER_2_BID_PRICE;
        let user_3_order_price = if (side == ASK)
            USER_3_ASK_PRICE else USER_3_BID_PRICE;
        let user_1_order_size = if (side == ASK)
            USER_1_ASK_SIZE else USER_1_BID_SIZE;
        let user_2_order_size = if (side == ASK)
            USER_2_ASK_SIZE else USER_2_BID_SIZE;
        let user_3_order_size = if (side == ASK)
            USER_3_ASK_SIZE else USER_3_BID_SIZE;
        // Define order ID for each user's upcoming order
        let id_1 = if (side == ASK) id_a(user_1_order_price, USER_1_VER_NUM)
            else id_b(user_1_order_price, USER_1_VER_NUM);
        let id_2 = if (side == ASK) id_a(user_2_order_price, USER_2_VER_NUM)
            else id_b(user_2_order_price, USER_2_VER_NUM);
        let id_3 = if (side == ASK) id_a(user_3_order_price, USER_3_VER_NUM)
            else id_b(user_3_order_price, USER_3_VER_NUM);
        if (side == ASK) { // Submit asks for each user if side is ask
            submit_ask<BCT, QCT, E1>(
                user_1, @Econia, user_1_order_price, user_1_order_size);
            submit_ask<BCT, QCT, E1>(
                user_2, @Econia, user_2_order_price, user_2_order_size);
            submit_ask<BCT, QCT, E1>(
                user_3, @Econia, user_3_order_price, user_3_order_size);
        } else { // Otherwise submit bids
            submit_bid<BCT, QCT, E1>(
                user_1, @Econia, user_1_order_price, user_1_order_size);
            submit_bid<BCT, QCT, E1>(
                user_2, @Econia, user_2_order_price, user_2_order_size);
            submit_bid<BCT, QCT, E1>(
                user_3, @Econia, user_3_order_price, user_3_order_size);
        };
        (id_1, id_2, id_3) // Return order ids
    }

    // Test-only functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    // Tests >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    /// Verify matching when user 0's market order clears out the entire
    /// book and is still left unfilled
    public entry fun ask_clear_book(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        let side = ASK; // Define book side market order fills against
        let market_order_size = 27; // Define market order size
        // Initialize market with positions, storing order ids
        let (id_1, id_2, id_3) =
            init_market(side, econia, user_0, user_1, user_2, user_3);
        // Fill the market order of given size
        submit_market_buy<BCT, QCT, E1>(user_0, @Econia,
            market_order_size, USER_0_START_QUOTE);
        // Get interpreted collateral field values for user 0
        let (u_0_b_available, u_0_b_coins, u_0_q_available, u_0_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser);
        // Calculate base coins filled
        let base_filled = SCALE_FACTOR *
            (USER_1_ASK_SIZE + USER_2_ASK_SIZE + USER_3_ASK_SIZE);
        // Calculate quote coins filled
        let quote_filled = USER_1_ASK_PRICE * USER_1_ASK_SIZE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE +
            USER_3_ASK_PRICE * USER_3_ASK_SIZE;
        // Assert correct collateral field values
        assert!(u_0_b_coins == USER_0_START_BASE + base_filled, 0);
        assert!(u_0_b_available == USER_0_START_BASE + base_filled, 0);
        assert!(u_0_q_coins == USER_0_START_QUOTE - quote_filled, 0);
        assert!(u_0_q_available == USER_0_START_QUOTE - quote_filled, 0);
        // Get interpreted collateral field values for user 1
        let (u_1_b_available, u_1_b_coins, u_1_q_available, u_1_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser1);
        // Assert correct collateral field values
        assert!(u_1_b_available == USER_1_START_BASE -
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        assert!(u_1_b_coins == USER_1_START_BASE -
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        assert!(u_1_q_available == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        assert!(u_1_q_coins == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        // Assert user 1 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser1, side, id_1), 0);
        // Assert user 1 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_1), 0);
        // Get interpreted collateral field values for user 2
        let (u_2_b_available, u_2_b_coins, u_2_q_available, u_2_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser2);
        // Assert correct collateral field values
        assert!(u_2_b_available == USER_2_START_BASE -
            SCALE_FACTOR * USER_2_ASK_SIZE, 0);
        assert!(u_2_b_coins == USER_2_START_BASE -
            SCALE_FACTOR * USER_2_ASK_SIZE, 0);
        assert!(u_2_q_available == USER_2_START_QUOTE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE, 0);
        assert!(u_2_q_coins == USER_2_START_QUOTE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE, 0);
        // Assert user 2 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser2, side, id_2), 0);
        // Assert user 2 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_2), 0);
        // Get interpreted collateral field values for user 3
        let (u_3_b_available, u_3_b_coins, u_3_q_available, u_3_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser3);
        // Assert correct collateral field values
        assert!(u_3_b_available == USER_3_START_BASE -
            SCALE_FACTOR * USER_3_ASK_SIZE, 0);
        assert!(u_3_b_coins == USER_3_START_BASE -
            SCALE_FACTOR * USER_3_ASK_SIZE, 0);
        assert!(u_3_q_available == USER_3_START_QUOTE +
            USER_3_ASK_PRICE * USER_3_ASK_SIZE, 0);
        assert!(u_3_q_coins == USER_3_START_QUOTE +
            USER_3_ASK_PRICE * USER_3_ASK_SIZE, 0);
        // Assert user 3 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser3, side, id_3), 0);
        // Assert user 3 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_3), 0);
        // Get extreme order id (min ask/max bid)
        let extreme_order_id = check_extreme_order_id<BCT, QCT, E1>(
            @Econia, side);
        // Assert correct value
        assert!(extreme_order_id == MIN_ASK_DEFAULT, 0);
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    /// Verify matching when user 0's market order is an exact fill
    /// against user 2's position
    public entry fun ask_exact_2(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        let side = ASK; // Define book side market order fills against
        let market_order_size = 17; // Define market order size
        // Initialize market with positions, storing order ids
        let (id_1, id_2, id_3) =
            init_market(side, econia, user_0, user_1, user_2, user_3);
        // Fill the market order of given size
        submit_market_buy<BCT, QCT, E1>(user_0, @Econia,
            market_order_size, USER_0_START_QUOTE);
        // Get interpreted collateral field values for user 0
        let (u_0_b_available, u_0_b_coins, u_0_q_available, u_0_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser);
        // Calculate base coins filled
        let base_filled = SCALE_FACTOR *
            (USER_1_ASK_SIZE + USER_2_ASK_SIZE);
        // Calculate quote coins filled
        let quote_filled = USER_1_ASK_PRICE * USER_1_ASK_SIZE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE;
        // Assert correct collateral field values
        assert!(u_0_b_coins == USER_0_START_BASE + base_filled, 0);
        assert!(u_0_b_available == USER_0_START_BASE + base_filled, 0);
        assert!(u_0_q_coins == USER_0_START_QUOTE - quote_filled, 0);
        assert!(u_0_q_available == USER_0_START_QUOTE - quote_filled, 0);
        // Get interpreted collateral field values for user 1
        let (u_1_b_available, u_1_b_coins, u_1_q_available, u_1_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser1);
        // Assert correct collateral field values
        assert!(u_1_b_available == USER_1_START_BASE -
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        assert!(u_1_b_coins == USER_1_START_BASE -
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        assert!(u_1_q_available == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        assert!(u_1_q_coins == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        // Assert user 1 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser1, side, id_1), 0);
        // Assert user 1 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_1), 0);
        // Get interpreted collateral field values for user 2
        let (u_2_b_available, u_2_b_coins, u_2_q_available, u_2_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser2);
        // Assert correct collateral field values
        assert!(u_2_b_available == USER_2_START_BASE -
            SCALE_FACTOR * USER_2_ASK_SIZE, 0);
        assert!(u_2_b_coins == USER_2_START_BASE -
            SCALE_FACTOR * USER_2_ASK_SIZE, 0);
        assert!(u_2_q_available == USER_2_START_QUOTE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE, 0);
        assert!(u_2_q_coins == USER_2_START_QUOTE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE, 0);
        // Assert user 2 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser2, side, id_2), 0);
        // Assert user 2 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_2), 0);
        // Get interpreted collateral field values for user 3
        let (u_3_b_available, u_3_b_coins, u_3_q_available, u_3_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser3);
        // Assert correct collateral field values
        assert!(u_3_b_available == USER_3_START_BASE -
            SCALE_FACTOR * USER_3_ASK_SIZE, 0);
        assert!(u_3_b_coins == USER_3_START_BASE, 0);
        assert!(u_3_q_available == USER_3_START_QUOTE, 0);
        assert!(u_3_q_coins == USER_3_START_QUOTE, 0);
        // Get user 3's open order size
        let u_3_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser3, side, id_3);
        // Assert correct value
        assert!(u_3_open_order_size == USER_3_ASK_SIZE, 0);
        // Get corresponding position on order book
        let (u_3_position_size, u_3_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_3);
        // Assert correct fields
        assert!(u_3_position_size == USER_3_ASK_SIZE, 0);
        assert!(u_3_position_address == @TestUser3, 0);
        // Get extreme order id (min ask/max bid)
        let extreme_order_id = check_extreme_order_id<BCT, QCT, E1>(
            @Econia, side);
        assert!(extreme_order_id == id_3, 0); // Assert correct value
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    /// Verify matching when user 0's market order is a partial fill
    /// against user 1's position
    public entry fun ask_partial_1(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        let side = ASK; // Define book side market order fills against
        let market_order_size = 5; // Define market order size
        // Initialize market with positions, storing order ids
        let (id_1, id_2, id_3) =
            init_market(side, econia, user_0, user_1, user_2, user_3);
        // Fill the market order of given size
        submit_market_buy<BCT, QCT, E1>(user_0, @Econia,
            market_order_size, USER_0_START_QUOTE);
        // Get interpreted collateral field values for user 0
        let (u_0_b_available, u_0_b_coins, u_0_q_available, u_0_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser);
        // Calculate base coins filled
        let base_filled = SCALE_FACTOR * market_order_size;
        // Calculate quote coins filled
        let quote_filled = USER_1_ASK_PRICE * market_order_size;
        // Assert correct collateral field values
        assert!(u_0_b_coins == USER_0_START_BASE + base_filled, 0);
        assert!(u_0_b_available == USER_0_START_BASE + base_filled, 0);
        assert!(u_0_q_coins == USER_0_START_QUOTE - quote_filled, 0);
        assert!(u_0_q_available == USER_0_START_QUOTE - quote_filled, 0);
        // Get interpreted collateral field values for user 1
        let (u_1_b_available, u_1_b_coins, u_1_q_available, u_1_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser1);
        // Assert correct collateral field values
        assert!(u_1_b_available == USER_1_START_BASE -
            SCALE_FACTOR * USER_1_ASK_SIZE, 0);
        assert!(u_1_b_coins == USER_1_START_BASE -
            SCALE_FACTOR * market_order_size, 0);
        assert!(u_1_q_available == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * market_order_size, 0);
        assert!(u_1_q_coins == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * market_order_size, 0);
        // Get user 1's open order size
        let u_1_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser1, side, id_1);
        // Assert correct value
        assert!(u_1_open_order_size == USER_1_ASK_SIZE - market_order_size, 0);
        // Get corresponding position on order book
        let (u_1_position_size, u_1_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_1);
        // Assert correct fields
        assert!(u_1_position_size == USER_1_ASK_SIZE - market_order_size, 0);
        assert!(u_1_position_address == @TestUser1, 0);
        // Get interpreted collateral field values for user 2
        let (u_2_b_available, u_2_b_coins, u_2_q_available, u_2_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser2);
        // Assert correct collateral field values
        assert!(u_2_b_available == USER_2_START_BASE -
            SCALE_FACTOR * USER_2_ASK_SIZE, 0);
        assert!(u_2_b_coins == USER_2_START_BASE, 0);
        assert!(u_2_q_available == USER_2_START_QUOTE, 0);
        assert!(u_2_q_coins == USER_2_START_QUOTE, 0);
        // Get user 2's open order size
        let u_2_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser2, side, id_2);
        // Assert correct value
        assert!(u_2_open_order_size == USER_2_ASK_SIZE, 0);
        // Get corresponding position on order book
        let (u_2_position_size, u_2_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_2);
        // Assert correct fields
        assert!(u_2_position_size == USER_2_ASK_SIZE, 0);
        assert!(u_2_position_address == @TestUser2, 0);
        // Get interpreted collateral field values for user 3
        let (u_3_b_available, u_3_b_coins, u_3_q_available, u_3_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser3);
        // Assert correct collateral field values
        assert!(u_3_b_available == USER_3_START_BASE -
            SCALE_FACTOR * USER_3_ASK_SIZE, 0);
        assert!(u_3_b_coins == USER_3_START_BASE, 0);
        assert!(u_3_q_available == USER_3_START_QUOTE, 0);
        assert!(u_3_q_coins == USER_3_START_QUOTE, 0);
        // Get user 3's open order size
        let u_3_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser3, side, id_3);
        // Assert correct value
        assert!(u_3_open_order_size == USER_3_ASK_SIZE, 0);
        // Get corresponding position on order book
        let (u_3_position_size, u_3_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_3);
        // Assert correct fields
        assert!(u_3_position_size == USER_3_ASK_SIZE, 0);
        assert!(u_3_position_address == @TestUser3, 0);
        // Get extreme order id (min ask/max bid)
        let extreme_order_id =
            check_extreme_order_id<BCT, QCT, E1>(@Econia, side);
        assert!(extreme_order_id == id_1, 0); // Assert correct value
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    /// Verify matching when user 0's market order is a partial fill
    /// against user 3's position
    public entry fun ask_partial_3(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        let side = ASK; // Define book side market order fills against
        let market_order_size = 20; // Define market order size
        // Compute amount filled against user 3
        let user_3_fill_size = market_order_size -
            USER_1_ASK_SIZE - USER_2_ASK_SIZE;
        // Initialize market with positions, storing order ids
        let (id_1, id_2, id_3) =
            init_market(side, econia, user_0, user_1, user_2, user_3);
        // Fill the market order of given size
        submit_market_buy<BCT, QCT, E1>(user_0, @Econia,
            market_order_size, USER_0_START_QUOTE);
        // Get interpreted collateral field values for user 0
        let (u_0_b_available, u_0_b_coins, u_0_q_available, u_0_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser);
        // Calculate base coins filled
        let base_filled = SCALE_FACTOR * market_order_size;
        // Calculate quote coins filled
        let quote_filled = USER_1_ASK_PRICE * USER_1_ASK_SIZE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE +
            USER_3_ASK_PRICE * user_3_fill_size;
        // Assert correct collateral field values
        assert!(u_0_b_coins == USER_0_START_BASE + base_filled, 0);
        assert!(u_0_b_available == USER_0_START_BASE + base_filled, 0);
        assert!(u_0_q_coins == USER_0_START_QUOTE - quote_filled, 0);
        assert!(u_0_q_available == USER_0_START_QUOTE - quote_filled, 0);
        // Get interpreted collateral field values for user 1
        let (u_1_b_available, u_1_b_coins, u_1_q_available, u_1_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser1);
        // Assert correct collateral field values
        assert!(u_1_b_available == USER_1_START_BASE -
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        assert!(u_1_b_coins == USER_1_START_BASE -
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        assert!(u_1_q_available == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        assert!(u_1_q_coins == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        // Assert user 1 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser1, side, id_1), 0);
        // Assert user 1 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_1), 0);
        // Get interpreted collateral field values for user 2
        let (u_2_b_available, u_2_b_coins, u_2_q_available, u_2_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser2);
        // Assert correct collateral field values
        assert!(u_2_b_available == USER_2_START_BASE -
            SCALE_FACTOR * USER_2_ASK_SIZE, 0);
        assert!(u_2_b_coins == USER_2_START_BASE -
            SCALE_FACTOR * USER_2_ASK_SIZE, 0);
        assert!(u_2_q_available == USER_2_START_QUOTE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE, 0);
        assert!(u_2_q_coins == USER_2_START_QUOTE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE, 0);
        // Assert user 2 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser2, side, id_2), 0);
        // Assert user 2 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_2), 0);
        // Get interpreted collateral field values for user 3
        let (u_3_b_available, u_3_b_coins, u_3_q_available, u_3_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser3);
        // Assert correct collateral field values
        assert!(u_3_b_available == USER_3_START_BASE -
            SCALE_FACTOR * USER_3_ASK_SIZE, 0);
        assert!(u_3_b_coins == USER_3_START_BASE -
            SCALE_FACTOR * user_3_fill_size, 0);
        assert!(u_3_q_available == USER_3_START_QUOTE +
            USER_3_ASK_PRICE * user_3_fill_size, 0);
        assert!(u_3_q_coins == USER_3_START_QUOTE +
            USER_3_ASK_PRICE * user_3_fill_size, 0);
        // Get user 3's open order size
        let u_3_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser3, side, id_3);
        // Assert correct value
        assert!(u_3_open_order_size == USER_3_ASK_SIZE - user_3_fill_size, 0);
        // Get corresponding position on order book
        let (u_3_position_size, u_3_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_3);
        // Assert correct fields
        assert!(u_3_position_size == USER_3_ASK_SIZE - user_3_fill_size, 0);
        assert!(u_3_position_address == @TestUser3, 0);
        // Get extreme order id (min ask/max bid)
        let extreme_order_id = check_extreme_order_id<BCT, QCT, E1>(
            @Econia, side);
        assert!(extreme_order_id == id_3, 0); // Assert correct value
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    /// Verify matching when user 0's market order is an exact fill
    /// against user 1's position
    public entry fun bid_exact_1(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        let side = BID; // Define book side market order fills against
        let market_order_size = 3; // Define market order size
        // Initialize market with positions, storing order ids
        let (id_1, id_2, id_3) =
            init_market(side, econia, user_0, user_1, user_2, user_3);
        // Fill the market order of given size
        submit_market_sell<BCT, QCT, E1>(user_0, @Econia, market_order_size);
        // Get interpreted collateral field values for user 0
        let (u_0_b_available, u_0_b_coins, u_0_q_available, u_0_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser);
        // Calculate base coins filled
        let base_filled = SCALE_FACTOR * USER_1_BID_SIZE;
        // Calculate quote coins filled
        let quote_filled = USER_1_BID_PRICE * USER_1_BID_SIZE;
        // Assert correct collateral field values
        assert!(u_0_b_coins == USER_0_START_BASE - base_filled, 0);
        assert!(u_0_b_available == USER_0_START_BASE - base_filled, 0);
        assert!(u_0_q_coins == USER_0_START_QUOTE + quote_filled, 0);
        assert!(u_0_q_available == USER_0_START_QUOTE + quote_filled, 0);
        // Get interpreted collateral field values for user 1
        let (u_1_b_available, u_1_b_coins, u_1_q_available, u_1_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser1);
        // Assert correct collateral field values
        assert!(u_1_b_available == USER_1_START_BASE +
            SCALE_FACTOR * USER_1_BID_SIZE, 0);
        assert!(u_1_b_coins == USER_1_START_BASE +
            SCALE_FACTOR * USER_1_BID_SIZE, 0);
        assert!(u_1_q_available == USER_1_START_QUOTE -
            USER_1_BID_PRICE * USER_1_BID_SIZE, 0);
        assert!(u_1_q_coins == USER_1_START_QUOTE -
            USER_1_BID_PRICE * USER_1_BID_SIZE, 0);
        // Assert user 1 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser1, side, id_1), 0);
        // Assert user 1 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_1), 0);
        // Get interpreted collateral field values for user 2
        let (u_2_b_available, u_2_b_coins, u_2_q_available, u_2_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser2);
        // Assert correct collateral field values
        assert!(u_2_b_available == USER_2_START_BASE, 0);
        assert!(u_2_b_coins == USER_2_START_BASE, 0);
        assert!(u_2_q_available == USER_2_START_QUOTE -
            USER_2_BID_PRICE * USER_2_BID_SIZE, 0);
        assert!(u_2_q_coins == USER_2_START_QUOTE, 0);
        // Get user 2's open order size
        let u_2_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser2, side, id_2);
        // Assert correct value
        assert!(u_2_open_order_size == USER_2_BID_SIZE, 0);
        // Get corresponding position on order book
        let (u_2_position_size, u_2_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_2);
        // Assert correct fields
        assert!(u_2_position_size == USER_2_BID_SIZE, 0);
        assert!(u_2_position_address == @TestUser2, 0);
        // Get interpreted collateral field values for user 3
        let (u_3_b_available, u_3_b_coins, u_3_q_available, u_3_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser3);
        // Assert correct collateral field values
        assert!(u_3_b_available == USER_3_START_BASE, 0);
        assert!(u_3_b_coins == USER_3_START_BASE, 0);
        assert!(u_3_q_available == USER_3_START_QUOTE -
            USER_3_BID_PRICE * USER_3_BID_SIZE, 0);
        assert!(u_3_q_coins == USER_3_START_QUOTE, 0);
        // Get user 3's open order size
        let u_3_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser3, side, id_3);
        // Assert correct value
        assert!(u_3_open_order_size == USER_3_BID_SIZE, 0);
        // Get corresponding position on order book
        let (u_3_position_size, u_3_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_3);
        // Assert correct fields
        assert!(u_3_position_size == USER_3_BID_SIZE, 0);
        assert!(u_3_position_address == @TestUser3, 0);
        // Get extreme order id (min ask/max bid)
        let extreme_order_id = check_extreme_order_id<BCT, QCT, E1>(
            @Econia, side);
        assert!(extreme_order_id == id_2, 0); // Assert correct value
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    /// Verify matching when user 0's market order is an exact fill
    /// against user 3's position
    public entry fun bid_exact_3(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        let side = BID; // Define book side market order fills against
        let market_order_size = 12; // Define market order size
        // Initialize market with positions, storing order ids
        let (id_1, id_2, id_3) =
            init_market(side, econia, user_0, user_1, user_2, user_3);
        // Fill the market order of given size
        submit_market_sell<BCT, QCT, E1>(user_0, @Econia, market_order_size);
        // Get interpreted collateral field values for user 0
        let (u_0_b_available, u_0_b_coins, u_0_q_available, u_0_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser);
        // Calculate base coins filled
        let base_filled = SCALE_FACTOR *
            (USER_1_BID_SIZE + USER_2_BID_SIZE + USER_3_BID_SIZE);
        // Calculate quote coins filled
        let quote_filled = USER_1_BID_PRICE * USER_1_BID_SIZE +
            USER_2_BID_PRICE * USER_2_BID_SIZE +
            USER_3_BID_PRICE * USER_3_BID_SIZE;
        // Assert correct collateral field values
        assert!(u_0_b_coins == USER_0_START_BASE - base_filled, 0);
        assert!(u_0_b_available == USER_0_START_BASE - base_filled, 0);
        assert!(u_0_q_coins == USER_0_START_QUOTE + quote_filled, 0);
        assert!(u_0_q_available == USER_0_START_QUOTE + quote_filled, 0);
        // Get interpreted collateral field values for user 1
        let (u_1_b_available, u_1_b_coins, u_1_q_available, u_1_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser1);
        // Assert correct collateral field values
        assert!(u_1_b_available == USER_1_START_BASE +
            SCALE_FACTOR * USER_1_BID_SIZE, 0);
        assert!(u_1_b_coins == USER_1_START_BASE +
            SCALE_FACTOR * USER_1_BID_SIZE, 0);
        assert!(u_1_q_available == USER_1_START_QUOTE -
            USER_1_BID_PRICE * USER_1_BID_SIZE, 0);
        assert!(u_1_q_coins == USER_1_START_QUOTE -
            USER_1_BID_PRICE * USER_1_BID_SIZE, 0);
        // Assert user 1 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser1, side, id_1), 0);
        // Assert user 1 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_1), 0);
        // Get interpreted collateral field values for user 2
        let (u_2_b_available, u_2_b_coins, u_2_q_available, u_2_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser2);
        // Assert correct collateral field values
        assert!(u_2_b_available == USER_2_START_BASE +
            SCALE_FACTOR * USER_2_BID_SIZE, 0);
        assert!(u_2_b_coins == USER_2_START_BASE +
            SCALE_FACTOR * USER_2_BID_SIZE, 0);
        assert!(u_2_q_available == USER_2_START_QUOTE -
            USER_2_BID_PRICE * USER_2_BID_SIZE, 0);
        assert!(u_2_q_coins == USER_2_START_QUOTE -
            USER_2_BID_PRICE * USER_2_BID_SIZE, 0);
        // Assert user 2 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser2, side, id_2), 0);
        // Assert user 2 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_2), 0);
        // Get interpreted collateral field values for user 3
        let (u_3_b_available, u_3_b_coins, u_3_q_available, u_3_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser3);
        // Assert correct collateral field values
        assert!(u_3_b_available == USER_3_START_BASE +
            SCALE_FACTOR * USER_3_BID_SIZE, 0);
        assert!(u_3_b_coins == USER_3_START_BASE +
            SCALE_FACTOR * USER_3_BID_SIZE, 0);
        assert!(u_3_q_available == USER_3_START_QUOTE -
            USER_3_BID_PRICE * USER_3_BID_SIZE, 0);
        assert!(u_3_q_coins == USER_3_START_QUOTE -
            USER_3_BID_PRICE * USER_3_BID_SIZE, 0);
        // Assert user 3 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser3, side, id_3), 0);
        // Assert user 3 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_3), 0);
        // Get extreme order id (min ask/max bid)
        let extreme_order_id = check_extreme_order_id<BCT, QCT, E1>(
            @Econia, side);
        // Assert correct value
        assert!(extreme_order_id == MAX_BID_DEFAULT, 0);
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    /// Verify matching when user 0's market order is a partial fill
    /// against user 2's position
    public entry fun bid_partial_2(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        let side = BID; // Define book side market order fills against
        let market_order_size = 5; // Define market order size
        // Initialize market with positions, storing order ids
        let (id_1, id_2, id_3) =
            init_market(side, econia, user_0, user_1, user_2, user_3);
        // Fill the market order of given size
        submit_market_sell<BCT, QCT, E1>(user_0, @Econia, market_order_size);
        // Get interpreted collateral field values for user 0
        let (u_0_b_available, u_0_b_coins, u_0_q_available, u_0_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser);
        // Calculate base coins filled against user 2
        let user_2_fill_size = market_order_size - USER_1_BID_SIZE;
        // Calculate base coins filled
        let base_filled = SCALE_FACTOR * (USER_1_BID_SIZE + user_2_fill_size);
        // Calculate quote coins filled
        let quote_filled = USER_1_BID_PRICE * USER_1_BID_SIZE +
            USER_2_BID_PRICE * user_2_fill_size;
        // Assert correct collateral field values
        assert!(u_0_b_coins == USER_0_START_BASE - base_filled, 0);
        assert!(u_0_b_available == USER_0_START_BASE - base_filled, 0);
        assert!(u_0_q_coins == USER_0_START_QUOTE + quote_filled, 0);
        assert!(u_0_q_available == USER_0_START_QUOTE + quote_filled, 0);
        // Get interpreted collateral field values for user 1
        let (u_1_b_available, u_1_b_coins, u_1_q_available, u_1_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser1);
        // Assert correct collateral field values
        assert!(u_1_b_available == USER_1_START_BASE +
            SCALE_FACTOR * USER_1_BID_SIZE, 0);
        assert!(u_1_b_coins == USER_1_START_BASE +
            SCALE_FACTOR * USER_1_BID_SIZE, 0);
        assert!(u_1_q_available == USER_1_START_QUOTE -
            USER_1_BID_PRICE * USER_1_BID_SIZE, 0);
        assert!(u_1_q_coins == USER_1_START_QUOTE -
            USER_1_BID_PRICE * USER_1_BID_SIZE, 0);
        // Assert user 1 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser1, side, id_1), 0);
        // Assert user 1 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_1), 0);
        // Get interpreted collateral field values for user 2
        let (u_2_b_available, u_2_b_coins, u_2_q_available, u_2_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser2);
        // Assert correct collateral field values
        assert!(u_2_b_available == USER_2_START_BASE +
            SCALE_FACTOR * (market_order_size - USER_1_BID_SIZE), 0);
        assert!(u_2_b_coins == USER_2_START_BASE +
            SCALE_FACTOR * (market_order_size - USER_1_BID_SIZE), 0);
        assert!(u_2_q_available == USER_2_START_QUOTE -
            USER_2_BID_PRICE * USER_2_BID_SIZE, 0);
        assert!(u_2_q_coins == USER_2_START_QUOTE -
            USER_2_BID_PRICE * (market_order_size - USER_1_BID_SIZE), 0);
        // Get user 2's open order size
        let u_2_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser2, side, id_2);
        // Assert correct value
        assert!(u_2_open_order_size == USER_2_BID_SIZE -
            (market_order_size - USER_1_BID_SIZE), 0);
        // Get corresponding position on order book
        let (u_2_position_size, u_2_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_2);
        // Assert correct fields
        assert!(u_2_position_size == USER_2_BID_SIZE -
            (market_order_size - USER_1_BID_SIZE), 0);
        assert!(u_2_position_address == @TestUser2, 0);
        // Get interpreted collateral field values for user 3
        let (u_3_b_available, u_3_b_coins, u_3_q_available, u_3_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser3);
        // Assert correct collateral field values
        assert!(u_3_b_available == USER_3_START_BASE, 0);
        assert!(u_3_b_coins == USER_3_START_BASE, 0);
        assert!(u_3_q_available == USER_3_START_QUOTE -
            USER_3_BID_PRICE * USER_3_BID_SIZE, 0);
        assert!(u_3_q_coins == USER_3_START_QUOTE, 0);
        // Get user 3's open order size
        let u_3_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser3, side, id_3);
        // Assert correct value
        assert!(u_3_open_order_size == USER_3_BID_SIZE, 0);
        // Get corresponding position on order book
        let (u_3_position_size, u_3_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_3);
        // Assert correct fields
        assert!(u_3_position_size == USER_3_BID_SIZE, 0);
        assert!(u_3_position_address == @TestUser3, 0);
        // Get extreme order id (min ask/max bid)
        let extreme_order_id = check_extreme_order_id<BCT, QCT, E1>(
            @Econia, side);
        assert!(extreme_order_id == id_2, 0); // Assert correct value
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    /// Verify matching when user 0's market buy has quote coins
    /// exhausted after exactly filling user 1's ask, when requested
    /// order size would have resulted in a complete target fill against
    /// user 1's position if quote coins had not run out first
    public entry fun buy_exhaust_exact_1_complete_requested(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        let side = ASK; // Define book side market order fills against
        // Define market order request size that would result in a
        // complete target fill against user 1, if enough quote coins
        // were available
        let market_order_size = USER_1_ASK_SIZE + 1;
        // Define max quote coins to spend
        let max_quote_to_spend = USER_1_ASK_PRICE * USER_1_ASK_SIZE;
        let user_0_end_base =
            USER_0_START_BASE + SCALE_FACTOR * USER_1_ASK_SIZE;
        // Calculate quote coins user 0 ends with
        let user_0_end_quote =
            USER_0_START_QUOTE - USER_1_ASK_PRICE * USER_1_ASK_SIZE;
        // Initialize market with positions, storing order ids
        let (id_1, id_2, id_3) =
            init_market(side, econia, user_0, user_1, user_2, user_3);
        // Fill the market order of given size
        submit_market_buy<BCT, QCT, E1>(user_0, @Econia,
            market_order_size, max_quote_to_spend);
        // Get interpreted collateral field values for user 0
        let (u_0_b_available, u_0_b_coins, u_0_q_available, u_0_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser);
        // Assert correct collateral field values
        assert!(u_0_b_coins == user_0_end_base, 0);
        assert!(u_0_b_available == user_0_end_base, 0);
        assert!(u_0_q_coins == user_0_end_quote, 0);
        assert!(u_0_q_available == user_0_end_quote, 0);
        // Get interpreted collateral field values for user 1
        let (u_1_b_available, u_1_b_coins, u_1_q_available, u_1_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser1);
        // Assert correct collateral field values
        assert!(u_1_b_available == USER_1_START_BASE -
            SCALE_FACTOR * USER_1_ASK_SIZE, 0);
        assert!(u_1_b_coins == USER_1_START_BASE -
            SCALE_FACTOR * USER_1_ASK_SIZE, 0);
        assert!(u_1_q_available == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        assert!(u_1_q_coins == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        // Assert user 1 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser1, side, id_1), 0);
        // Assert user 1 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_1), 0);
        // Get interpreted collateral field values for user 2
        let (u_2_b_available, u_2_b_coins, u_2_q_available, u_2_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser2);
        // Assert correct collateral field values
        assert!(u_2_b_available == USER_2_START_BASE -
            SCALE_FACTOR * USER_2_ASK_SIZE, 0);
        assert!(u_2_b_coins == USER_2_START_BASE, 0);
        assert!(u_2_q_available == USER_2_START_QUOTE, 0);
        assert!(u_2_q_coins == USER_2_START_QUOTE, 0);
        // Get user 2's open order size
        let u_2_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser2, side, id_2);
        // Assert correct value
        assert!(u_2_open_order_size == USER_2_ASK_SIZE, 0);
        // Get corresponding position on order book
        let (u_2_position_size, u_2_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_2);
        // Assert correct fields
        assert!(u_2_position_size == USER_2_ASK_SIZE, 0);
        assert!(u_2_position_address == @TestUser2, 0);
        // Get interpreted collateral field values for user 3
        let (u_3_b_available, u_3_b_coins, u_3_q_available, u_3_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser3);
        // Assert correct collateral field values
        assert!(u_3_b_available == USER_3_START_BASE -
            SCALE_FACTOR * USER_3_ASK_SIZE, 0);
        assert!(u_3_b_coins == USER_3_START_BASE, 0);
        assert!(u_3_q_available == USER_3_START_QUOTE, 0);
        assert!(u_3_q_coins == USER_3_START_QUOTE, 0);
        // Get user 3's open order size
        let u_3_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser3, side, id_3);
        // Assert correct value
        assert!(u_3_open_order_size == USER_3_ASK_SIZE, 0);
        // Get corresponding position on order book
        let (u_3_position_size, u_3_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_3);
        // Assert correct fields
        assert!(u_3_position_size == USER_3_ASK_SIZE, 0);
        assert!(u_3_position_address == @TestUser3, 0);
        // Get extreme order id (min ask/max bid)
        let extreme_order_id =
            check_extreme_order_id<BCT, QCT, E1>(@Econia, side);
        assert!(extreme_order_id == id_2, 0); // Assert correct value
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    /// Verify matching when user 0's market buy has quote coins
    /// exhausted after exactly filling user 2's ask, when requested
    /// order size also specifies and exact target fill against user 2's
    /// position
    public entry fun buy_exhaust_exact_2_exact_requested(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        let side = ASK; // Define book side market order fills against
        // Define market order request size for exact fill against user
        // 2's position
        let market_order_size = USER_1_ASK_SIZE + USER_2_ASK_SIZE;
        // Define number of parcels filled against user 2's ask
        // Define max quote coins to spend
        let max_quote_to_spend =
            USER_1_ASK_PRICE * USER_1_ASK_SIZE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE;
        // Calculate base coins user 0 ends with
        let user_0_end_base = USER_0_START_BASE + SCALE_FACTOR *
            (USER_1_ASK_SIZE + USER_2_ASK_SIZE);
        // Calculate quote coins user 0 ends with
        let user_0_end_quote = USER_0_START_QUOTE -
            USER_1_ASK_PRICE * USER_1_ASK_SIZE -
            USER_2_ASK_PRICE * USER_2_ASK_SIZE;
        // Initialize market with positions, storing order ids
        let (id_1, id_2, id_3) =
            init_market(side, econia, user_0, user_1, user_2, user_3);
        // Fill the market order of given size
        submit_market_buy<BCT, QCT, E1>(user_0, @Econia,
            market_order_size, max_quote_to_spend);
        // Get interpreted collateral field values for user 0
        let (u_0_b_available, u_0_b_coins, u_0_q_available, u_0_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser);
        // Assert correct collateral field values
        assert!(u_0_b_coins == user_0_end_base, 0);
        assert!(u_0_b_available == user_0_end_base, 0);
        assert!(u_0_q_coins == user_0_end_quote, 0);
        assert!(u_0_q_available == user_0_end_quote, 0);
        // Get interpreted collateral field values for user 1
        let (u_1_b_available, u_1_b_coins, u_1_q_available, u_1_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser1);
        // Assert correct collateral field values
        assert!(u_1_b_available == USER_1_START_BASE -
            SCALE_FACTOR * USER_1_ASK_SIZE, 0);
        assert!(u_1_b_coins == USER_1_START_BASE -
            SCALE_FACTOR * USER_1_ASK_SIZE, 0);
        assert!(u_1_q_available == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        assert!(u_1_q_coins == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        // Assert user 1 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser1, side, id_1), 0);
        // Assert user 1 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_1), 0);
        // Get interpreted collateral field values for user 2
        let (u_2_b_available, u_2_b_coins, u_2_q_available, u_2_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser2);
        // Assert correct collateral field values
        assert!(u_2_b_available == USER_2_START_BASE -
            SCALE_FACTOR * USER_2_ASK_SIZE, 0);
        assert!(u_2_b_coins == USER_2_START_BASE -
            SCALE_FACTOR * USER_2_ASK_SIZE, 0);
        assert!(u_2_q_available == USER_2_START_QUOTE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE, 0);
        assert!(u_2_q_coins == USER_2_START_QUOTE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE, 0);
        // Assert user 2 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser1, side, id_2), 0);
        // Assert user 2 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_2), 0);
        // Get interpreted collateral field values for user 3
        let (u_3_b_available, u_3_b_coins, u_3_q_available, u_3_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser3);
        // Assert correct collateral field values
        assert!(u_3_b_available == USER_3_START_BASE -
            SCALE_FACTOR * USER_3_ASK_SIZE, 0);
        assert!(u_3_b_coins == USER_3_START_BASE, 0);
        assert!(u_3_q_available == USER_3_START_QUOTE, 0);
        assert!(u_3_q_coins == USER_3_START_QUOTE, 0);
        // Get user 3's open order size
        let u_3_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser3, side, id_3);
        // Assert correct value
        assert!(u_3_open_order_size == USER_3_ASK_SIZE, 0);
        // Get corresponding position on order book
        let (u_3_position_size, u_3_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_3);
        // Assert correct fields
        assert!(u_3_position_size == USER_3_ASK_SIZE, 0);
        assert!(u_3_position_address == @TestUser3, 0);
        // Get extreme order id (min ask/max bid)
        let extreme_order_id =
            check_extreme_order_id<BCT, QCT, E1>(@Econia, side);
        assert!(extreme_order_id == id_3, 0); // Assert correct value
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    /// Verify matching when user 0's market buy has quote coins
    /// exhausted after exactly filling user 3's ask, when requested
    /// order size would have resulted in a complete target fill against
    /// user 3's position if quote coins had not run out first and if
    /// there was more depth on the book
    public entry fun buy_exhaust_exact_3_complete_requested(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        let side = ASK; // Define book side market order fills against
        // Define market fill request size that clears book
        let market_order_size =
            USER_1_ASK_SIZE + USER_2_ASK_SIZE + USER_3_ASK_SIZE + 1;
        // Define max quote coins to spend
        let max_quote_to_spend =
            USER_1_ASK_PRICE * USER_1_ASK_SIZE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE +
            USER_3_ASK_PRICE * USER_3_ASK_SIZE;
        // Calculate base coins user 0 ends with
        let user_0_end_base = USER_0_START_BASE + SCALE_FACTOR *
            (USER_1_ASK_SIZE + USER_2_ASK_SIZE + USER_3_ASK_SIZE);
        // Calculate quote coins user 0 ends with
        let user_0_end_quote = USER_0_START_QUOTE - max_quote_to_spend;
        // Initialize market with positions, storing order ids
        let (id_1, id_2, id_3) =
            init_market(side, econia, user_0, user_1, user_2, user_3);
        // Fill the market order of given size
        submit_market_buy<BCT, QCT, E1>(user_0, @Econia,
            market_order_size, max_quote_to_spend);
        // Get interpreted collateral field values for user 0
        let (u_0_b_available, u_0_b_coins, u_0_q_available, u_0_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser);
        // Assert correct collateral field values
        assert!(u_0_b_coins == user_0_end_base, 0);
        assert!(u_0_b_available == user_0_end_base, 0);
        assert!(u_0_q_coins == user_0_end_quote, 0);
        assert!(u_0_q_available == user_0_end_quote, 0);
        // Get interpreted collateral field values for user 1
        let (u_1_b_available, u_1_b_coins, u_1_q_available, u_1_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser1);
        // Assert correct collateral field values
        assert!(u_1_b_available == USER_1_START_BASE -
            SCALE_FACTOR * USER_1_ASK_SIZE, 0);
        assert!(u_1_b_coins == USER_1_START_BASE -
            SCALE_FACTOR * USER_1_ASK_SIZE, 0);
        assert!(u_1_q_available == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        assert!(u_1_q_coins == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        // Assert user 1 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser1, side, id_1), 0);
        // Assert user 1 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_1), 0);
        // Get interpreted collateral field values for user 2
        let (u_2_b_available, u_2_b_coins, u_2_q_available, u_2_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser2);
        // Assert correct collateral field values
        assert!(u_2_b_available == USER_2_START_BASE -
            SCALE_FACTOR * USER_2_ASK_SIZE, 0);
        assert!(u_2_b_coins == USER_2_START_BASE -
            SCALE_FACTOR * USER_2_ASK_SIZE, 0);
        assert!(u_2_q_available == USER_2_START_QUOTE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE, 0);
        assert!(u_2_q_coins == USER_2_START_QUOTE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE, 0);
        // Assert user 2 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser1, side, id_2), 0);
        // Assert user 2 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_2), 0);
        // Get interpreted collateral field values for user 3
        let (u_3_b_available, u_3_b_coins, u_3_q_available, u_3_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser3);
        // Assert correct collateral field values
        assert!(u_3_b_available == USER_3_START_BASE -
            SCALE_FACTOR * USER_3_ASK_SIZE, 0);
        assert!(u_3_b_coins == USER_3_START_BASE -
            SCALE_FACTOR * USER_3_ASK_SIZE, 0);
        assert!(u_3_q_available == USER_3_START_QUOTE +
            USER_3_ASK_PRICE * USER_3_ASK_SIZE, 0);
        assert!(u_3_q_coins == USER_3_START_QUOTE +
            USER_3_ASK_PRICE * USER_3_ASK_SIZE, 0);
        // Assert user 3 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser1, side, id_3), 0);
        // Assert user 3 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_3), 0);
        // Get extreme order id (min ask/max bid)
        let extreme_order_id =
            check_extreme_order_id<BCT, QCT, E1>(@Econia, side);
        // Assert correct value
        assert!(extreme_order_id == MIN_ASK_DEFAULT, 0);
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    /// Verify matching when user 0's market buy has quote coins
    /// exhausted immediately
    public entry fun buy_exhaust_immediately(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        let side = ASK; // Define book side market order fills against
        let market_order_size = 20; // Define market order size
        let max_quote_to_spend = 8; // Define max quote coins to spend
        // Initialize market with positions, storing order ids
        let (id_1, id_2, id_3) =
            init_market(side, econia, user_0, user_1, user_2, user_3);
        // Fill the market order of given size
        submit_market_buy<BCT, QCT, E1>(user_0, @Econia,
            market_order_size, max_quote_to_spend);
        // Get interpreted collateral field values for user 0
        let (u_0_b_available, u_0_b_coins, u_0_q_available, u_0_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser);
        // Assert correct collateral field values
        assert!(u_0_b_coins == USER_0_START_BASE, 0);
        assert!(u_0_b_available == USER_0_START_BASE, 0);
        assert!(u_0_q_coins == USER_0_START_QUOTE, 0);
        assert!(u_0_q_available == USER_0_START_QUOTE, 0);
        // Get interpreted collateral field values for user 1
        let (u_1_b_available, u_1_b_coins, u_1_q_available, u_1_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser1);
        // Assert correct collateral field values
        assert!(u_1_b_available == USER_1_START_BASE -
            SCALE_FACTOR * USER_1_ASK_SIZE, 0);
        assert!(u_1_b_coins == USER_1_START_BASE, 0);
        assert!(u_1_q_available == USER_1_START_QUOTE, 0);
        assert!(u_1_q_coins == USER_1_START_QUOTE, 0);
        // Get user 1's open order size
        let u_1_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser1, side, id_1);
        // Assert correct value
        assert!(u_1_open_order_size == USER_1_ASK_SIZE, 0);
        // Get interpreted collateral field values for user 2
        let (u_2_b_available, u_2_b_coins, u_2_q_available, u_2_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser2);
        // Assert correct collateral field values
        assert!(u_2_b_available == USER_2_START_BASE -
            SCALE_FACTOR * USER_2_ASK_SIZE, 0);
        assert!(u_2_b_coins == USER_2_START_BASE, 0);
        assert!(u_2_q_available == USER_2_START_QUOTE, 0);
        assert!(u_2_q_coins == USER_2_START_QUOTE, 0);
        // Get user 2's open order size
        let u_2_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser2, side, id_2);
        // Assert correct value
        assert!(u_2_open_order_size == USER_2_ASK_SIZE, 0);
        // Get corresponding position on order book
        let (u_2_position_size, u_2_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_2);
        // Assert correct fields
        assert!(u_2_position_size == USER_2_ASK_SIZE, 0);
        assert!(u_2_position_address == @TestUser2, 0);
        // Get interpreted collateral field values for user 3
        let (u_3_b_available, u_3_b_coins, u_3_q_available, u_3_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser3);
        // Assert correct collateral field values
        assert!(u_3_b_available == USER_3_START_BASE -
            SCALE_FACTOR * USER_3_ASK_SIZE, 0);
        assert!(u_3_b_coins == USER_3_START_BASE, 0);
        assert!(u_3_q_available == USER_3_START_QUOTE, 0);
        assert!(u_3_q_coins == USER_3_START_QUOTE, 0);
        // Get user 3's open order size
        let u_3_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser3, side, id_3);
        // Assert correct value
        assert!(u_3_open_order_size == USER_3_ASK_SIZE, 0);
        // Get corresponding position on order book
        let (u_3_position_size, u_3_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_3);
        // Assert correct fields
        assert!(u_3_position_size == USER_3_ASK_SIZE, 0);
        assert!(u_3_position_address == @TestUser3, 0);
        // Get extreme order id (min ask/max bid)
        let extreme_order_id =
            check_extreme_order_id<BCT, QCT, E1>(@Econia, side);
        assert!(extreme_order_id == id_1, 0); // Assert correct value
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    /// Verify matching when user 0's market buy has quote coins
    /// exhausted after partially filling user 1's ask, when requested
    /// order size would have resulted in a complete target fill against
    /// user 1's position if quote coins had not run out first
    public entry fun buy_exhaust_partial_1_complete_requested(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        let side = ASK; // Define book side market order fills against
        // Define market order request size that would result in a
        // complete target fill against user 1, if enough quote coins
        // were available
        let market_order_size = USER_1_ASK_SIZE + 1;
        // Define parcels filled against user 1's ask
        let filled_against_1 = USER_1_ASK_SIZE - 1;
        // Define max quote coins to spend
        let max_quote_to_spend = USER_1_ASK_PRICE * filled_against_1;
        // Calculate base coins user 0 ends with
        let user_0_end_base =
            USER_0_START_BASE + SCALE_FACTOR * filled_against_1;
        // Calculate quote coins user 0 ends with
        let user_0_end_quote =
            USER_0_START_QUOTE - USER_1_ASK_PRICE * filled_against_1;
        // Initialize market with positions, storing order ids
        let (id_1, id_2, id_3) =
            init_market(side, econia, user_0, user_1, user_2, user_3);
        // Fill the market order of given size
        submit_market_buy<BCT, QCT, E1>(user_0, @Econia,
            market_order_size, max_quote_to_spend);
        // Get interpreted collateral field values for user 0
        let (u_0_b_available, u_0_b_coins, u_0_q_available, u_0_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser);
        // Assert correct collateral field values
        assert!(u_0_b_coins == user_0_end_base, 0);
        assert!(u_0_b_available == user_0_end_base, 0);
        assert!(u_0_q_coins == user_0_end_quote, 0);
        assert!(u_0_q_available == user_0_end_quote, 0);
        // Get interpreted collateral field values for user 1
        let (u_1_b_available, u_1_b_coins, u_1_q_available, u_1_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser1);
        // Assert correct collateral field values
        assert!(u_1_b_available == USER_1_START_BASE -
            SCALE_FACTOR * USER_1_ASK_SIZE, 0);
        assert!(u_1_b_coins == USER_1_START_BASE -
            SCALE_FACTOR * filled_against_1, 0);
        assert!(u_1_q_available == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * filled_against_1, 0);
        assert!(u_1_q_coins == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * filled_against_1, 0);
        // Get user 1's open order size
        let u_1_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser1, side, id_1);
        // Assert correct value
        assert!(u_1_open_order_size == USER_1_ASK_SIZE - filled_against_1, 0);
        // Get interpreted collateral field values for user 2
        let (u_2_b_available, u_2_b_coins, u_2_q_available, u_2_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser2);
        // Assert correct collateral field values
        assert!(u_2_b_available == USER_2_START_BASE -
            SCALE_FACTOR * USER_2_ASK_SIZE, 0);
        assert!(u_2_b_coins == USER_2_START_BASE, 0);
        assert!(u_2_q_available == USER_2_START_QUOTE, 0);
        assert!(u_2_q_coins == USER_2_START_QUOTE, 0);
        // Get user 2's open order size
        let u_2_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser2, side, id_2);
        // Assert correct value
        assert!(u_2_open_order_size == USER_2_ASK_SIZE, 0);
        // Get corresponding position on order book
        let (u_2_position_size, u_2_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_2);
        // Assert correct fields
        assert!(u_2_position_size == USER_2_ASK_SIZE, 0);
        assert!(u_2_position_address == @TestUser2, 0);
        // Get interpreted collateral field values for user 3
        let (u_3_b_available, u_3_b_coins, u_3_q_available, u_3_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser3);
        // Assert correct collateral field values
        assert!(u_3_b_available == USER_3_START_BASE -
            SCALE_FACTOR * USER_3_ASK_SIZE, 0);
        assert!(u_3_b_coins == USER_3_START_BASE, 0);
        assert!(u_3_q_available == USER_3_START_QUOTE, 0);
        assert!(u_3_q_coins == USER_3_START_QUOTE, 0);
        // Get user 3's open order size
        let u_3_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser3, side, id_3);
        // Assert correct value
        assert!(u_3_open_order_size == USER_3_ASK_SIZE, 0);
        // Get corresponding position on order book
        let (u_3_position_size, u_3_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_3);
        // Assert correct fields
        assert!(u_3_position_size == USER_3_ASK_SIZE, 0);
        assert!(u_3_position_address == @TestUser3, 0);
        // Get extreme order id (min ask/max bid)
        let extreme_order_id =
            check_extreme_order_id<BCT, QCT, E1>(@Econia, side);
        assert!(extreme_order_id == id_1, 0); // Assert correct value
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    /// Verify matching when user 0's market buy has quote coins
    /// exhausted after partially filling user 2's ask, when requested
    /// order size would have resulted in an exact target fill if quote
    /// coins had not run out first
    public entry fun buy_exhaust_partial_2_exact_requested(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        let side = ASK; // Define book side market order fills against
        // Define market order request size that would result in an
        // exact target fill against user 2, if enough quote coins were
        // available
        let market_order_size = USER_1_ASK_SIZE + USER_2_ASK_SIZE;
        // Define number of parcels actually filled against user 2's ask
        let filled_against_2 = USER_2_ASK_SIZE - 3;
        // Define max quote coins to spend
        let max_quote_to_spend =
            USER_1_ASK_PRICE * USER_1_ASK_SIZE +
            USER_2_ASK_PRICE * filled_against_2;
        // Calculate base coins user 0 ends with
        let user_0_end_base = USER_0_START_BASE + SCALE_FACTOR *
            (USER_1_ASK_SIZE + filled_against_2);
        // Calculate quote coins user 0 ends with
        let user_0_end_quote = USER_0_START_QUOTE -
            USER_1_ASK_PRICE * USER_1_ASK_SIZE -
            USER_2_ASK_PRICE * filled_against_2;
        // Initialize market with positions, storing order ids
        let (id_1, id_2, id_3) =
            init_market(side, econia, user_0, user_1, user_2, user_3);
        // Fill the market order of given size
        submit_market_buy<BCT, QCT, E1>(user_0, @Econia,
            market_order_size, max_quote_to_spend);
        // Get interpreted collateral field values for user 0
        let (u_0_b_available, u_0_b_coins, u_0_q_available, u_0_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser);
        // Assert correct collateral field values
        assert!(u_0_b_coins == user_0_end_base, 0);
        assert!(u_0_b_available == user_0_end_base, 0);
        assert!(u_0_q_coins == user_0_end_quote, 0);
        assert!(u_0_q_available == user_0_end_quote, 0);
        // Get interpreted collateral field values for user 1
        let (u_1_b_available, u_1_b_coins, u_1_q_available, u_1_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser1);
        // Assert correct collateral field values
        assert!(u_1_b_available == USER_1_START_BASE -
            SCALE_FACTOR * USER_1_ASK_SIZE, 0);
        assert!(u_1_b_coins == USER_1_START_BASE -
            SCALE_FACTOR * USER_1_ASK_SIZE, 0);
        assert!(u_1_q_available == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        assert!(u_1_q_coins == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        // Assert user 1 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser1, side, id_1), 0);
        // Assert user 1 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_1), 0);
        // Get interpreted collateral field values for user 2
        let (u_2_b_available, u_2_b_coins, u_2_q_available, u_2_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser2);
        // Assert correct collateral field values
        assert!(u_2_b_available == USER_2_START_BASE -
            SCALE_FACTOR * USER_2_ASK_SIZE, 0);
        assert!(u_2_b_coins == USER_2_START_BASE -
            SCALE_FACTOR * filled_against_2, 0);
        assert!(u_2_q_available == USER_2_START_QUOTE +
            USER_2_ASK_PRICE * filled_against_2, 0);
        assert!(u_2_q_coins == USER_2_START_QUOTE +
            USER_2_ASK_PRICE * filled_against_2, 0);
        // Get user 2's open order size
        let u_2_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser2, side, id_2);
        // Assert correct value
        assert!(u_2_open_order_size == USER_2_ASK_SIZE - filled_against_2, 0);
        // Get corresponding position on order book
        let (u_2_position_size, u_2_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_2);
        // Assert correct fields
        assert!(u_2_position_size == USER_2_ASK_SIZE - filled_against_2, 0);
        assert!(u_2_position_address == @TestUser2, 0);
        // Get interpreted collateral field values for user 3
        let (u_3_b_available, u_3_b_coins, u_3_q_available, u_3_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser3);
        // Assert correct collateral field values
        assert!(u_3_b_available == USER_3_START_BASE -
            SCALE_FACTOR * USER_3_ASK_SIZE, 0);
        assert!(u_3_b_coins == USER_3_START_BASE, 0);
        assert!(u_3_q_available == USER_3_START_QUOTE, 0);
        assert!(u_3_q_coins == USER_3_START_QUOTE, 0);
        // Get user 3's open order size
        let u_3_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser3, side, id_3);
        // Assert correct value
        assert!(u_3_open_order_size == USER_3_ASK_SIZE, 0);
        // Get corresponding position on order book
        let (u_3_position_size, u_3_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_3);
        // Assert correct fields
        assert!(u_3_position_size == USER_3_ASK_SIZE, 0);
        assert!(u_3_position_address == @TestUser3, 0);
        // Get extreme order id (min ask/max bid)
        let extreme_order_id =
            check_extreme_order_id<BCT, QCT, E1>(@Econia, side);
        assert!(extreme_order_id == id_2, 0); // Assert correct value
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    /// Verify matching when user 0's market buy has quote coins
    /// exhausted after partially filling user 3's ask, when requested
    /// order size would have resulted in a larger partial target fill
    /// if quote coins had not run out first
    public entry fun buy_exhaust_partial_3_larger_partial_requested(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        let side = ASK; // Define book side market order fills against
        // Define market order request size for the largest possible
        // partial fill against user 3's order
        let market_order_size =
            USER_1_ASK_SIZE + USER_2_ASK_SIZE + (USER_3_ASK_SIZE - 1);
        // Define number of parcels actually filled against user 3's ask
        let filled_against_3 = USER_3_ASK_SIZE - 3;
        // Define max quote coins to spend
        let max_quote_to_spend =
            USER_1_ASK_PRICE * USER_1_ASK_SIZE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE +
            USER_3_ASK_PRICE * filled_against_3;
        // Calculate base coins user 0 ends with
        let user_0_end_base = USER_0_START_BASE + SCALE_FACTOR *
            (USER_1_ASK_SIZE + USER_2_ASK_SIZE + filled_against_3);
        // Calculate quote coins user 0 ends with
        let user_0_end_quote = USER_0_START_QUOTE -
            USER_1_ASK_PRICE * USER_1_ASK_SIZE -
            USER_2_ASK_PRICE * USER_2_ASK_SIZE -
            USER_3_ASK_PRICE * filled_against_3;
        // Initialize market with positions, storing order ids
        let (id_1, id_2, id_3) =
            init_market(side, econia, user_0, user_1, user_2, user_3);
        // Fill the market order of given size
        submit_market_buy<BCT, QCT, E1>(user_0, @Econia,
            market_order_size, max_quote_to_spend);
        // Get interpreted collateral field values for user 0
        let (u_0_b_available, u_0_b_coins, u_0_q_available, u_0_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser);
        // Assert correct collateral field values
        assert!(u_0_b_coins == user_0_end_base, 0);
        assert!(u_0_b_available == user_0_end_base, 0);
        assert!(u_0_q_coins == user_0_end_quote, 0);
        assert!(u_0_q_available == user_0_end_quote, 0);
        // Get interpreted collateral field values for user 1
        let (u_1_b_available, u_1_b_coins, u_1_q_available, u_1_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser1);
        // Assert correct collateral field values
        assert!(u_1_b_available == USER_1_START_BASE -
            SCALE_FACTOR * USER_1_ASK_SIZE, 0);
        assert!(u_1_b_coins == USER_1_START_BASE -
            SCALE_FACTOR * USER_1_ASK_SIZE, 0);
        assert!(u_1_q_available == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        assert!(u_1_q_coins == USER_1_START_QUOTE +
            USER_1_ASK_PRICE * USER_1_ASK_SIZE, 0);
        // Assert user 1 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser1, side, id_1), 0);
        // Assert user 1 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_1), 0);
        // Get interpreted collateral field values for user 2
        let (u_2_b_available, u_2_b_coins, u_2_q_available, u_2_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser2);
        // Assert correct collateral field values
        assert!(u_2_b_available == USER_2_START_BASE -
            SCALE_FACTOR * USER_2_ASK_SIZE, 0);
        assert!(u_2_b_coins == USER_2_START_BASE -
            SCALE_FACTOR * USER_2_ASK_SIZE, 0);
        assert!(u_2_q_available == USER_2_START_QUOTE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE, 0);
        assert!(u_2_q_coins == USER_2_START_QUOTE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE, 0);
        // Assert user 2 no longer has open order
        assert!(!has_order<BCT, QCT, E1>(@TestUser1, side, id_2), 0);
        // Assert user 2 no longer has position on order book
        assert!(!has_position<BCT, QCT, E1>(@Econia, side, id_2), 0);
        // Get interpreted collateral field values for user 3
        let (u_3_b_available, u_3_b_coins, u_3_q_available, u_3_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser3);
        // Assert correct collateral field values
        assert!(u_3_b_available == USER_3_START_BASE -
            SCALE_FACTOR * USER_3_ASK_SIZE, 0);
        assert!(u_3_b_coins == USER_3_START_BASE -
            SCALE_FACTOR * filled_against_3, 0);
        assert!(u_3_q_available == USER_3_START_QUOTE +
            USER_3_ASK_PRICE * filled_against_3, 0);
        assert!(u_3_q_coins == USER_3_START_QUOTE +
            USER_3_ASK_PRICE * filled_against_3, 0);
        // Get user 3's open order size
        let u_3_open_order_size = check_order<BCT, QCT, E1>(
            @TestUser3, side, id_3);
        // Assert correct value
        assert!(u_3_open_order_size == USER_3_ASK_SIZE - filled_against_3, 0);
        // Get corresponding position on order book
        let (u_3_position_size, u_3_position_address) =
            check_position<BCT, QCT, E1>(@Econia, side, id_3);
        // Assert correct fields
        assert!(u_3_position_size == USER_3_ASK_SIZE - filled_against_3, 0);
        assert!(u_3_position_address == @TestUser3, 0);
        // Get extreme order id (min ask/max bid)
        let extreme_order_id =
            check_extreme_order_id<BCT, QCT, E1>(@Econia, side);
        assert!(extreme_order_id == id_3, 0); // Assert correct value
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    #[expected_failure(abort_code = 2)]
    /// Verify no funds routed when no positions on book
    public entry fun no_positions(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        let side = ASK; // Define book side market order fills against
        // Define market order size that completely clears out book
        let market_order_size =
            USER_1_ASK_SIZE + USER_2_ASK_SIZE + USER_3_ASK_SIZE;
        // Calculate user 0's base coins after clearing book
        let user_0_end_base = USER_0_START_BASE +
            SCALE_FACTOR * market_order_size;
        // Calculate quote coins filled
        let quote_filled = USER_1_ASK_PRICE * USER_1_ASK_SIZE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE +
            USER_3_ASK_PRICE * USER_3_ASK_SIZE;
        // Calculate user 0's quote coins after clearing book
        let user_0_end_quote = USER_0_START_QUOTE - quote_filled;
        // Initialize market with positions to be completely cleared
        init_market(side, econia, user_0, user_1, user_2, user_3);
        // Fill the market order of given size
        submit_market_buy<BCT, QCT, E1>(user_0, @Econia,
            market_order_size, USER_0_START_QUOTE);
        // Get interpreted collateral field values for user 0
        let (u_0_b_available, u_0_b_coins, u_0_q_available, u_0_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser);
        // Assert correct collateral field values
        assert!(u_0_b_coins == user_0_end_base, 0);
        assert!(u_0_b_available == user_0_end_base, 0);
        assert!(u_0_q_coins == user_0_end_quote, 0);
        assert!(u_0_q_available == user_0_end_quote, 0);
        // Update user 0 sequence counter so can place another order
        increment_sequence_number(@TestUser);
        // Try submitting another market order of same size
        submit_market_buy<BCT, QCT, E1>(user_0, @Econia,
            market_order_size, USER_0_START_QUOTE);
        // Assert collateral field values unchanged
        assert!(u_0_b_coins == user_0_end_base, 0);
        assert!(u_0_b_available == user_0_end_base, 0);
        assert!(u_0_q_coins == user_0_end_quote, 0);
        assert!(u_0_q_available == user_0_end_quote, 0);
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    #[expected_failure(abort_code = 2)]
    /// Verify failure when insufficient base coins to place market sell
    public entry fun submit_market_order_failure_insufficient_base(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        // Initialize market with positions
        init_market(BID, econia, user_0, user_1, user_2, user_3);
        // Attempt invalid market sell
        submit_market_sell<BCT, QCT, E1>(user_0, @Econia,
            USER_0_START_BASE / SCALE_FACTOR + 1);
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    #[expected_failure(abort_code = 2)]
    /// Verify failure when insufficient quote coins to place market buy
    public entry fun submit_market_order_failure_insufficient_quote(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        // Initialize market with positions
        init_market(ASK, econia, user_0, user_1, user_2, user_3);
        // Attempt invalid market buy
        submit_market_buy<BCT, QCT, E1>(
            user_0, @Econia, 1, USER_0_START_QUOTE + 1);
    }
    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    #[expected_failure(abort_code = 1)]
    /// Verify failure when no collateral container
    public entry fun submit_market_order_failure_no_collateral(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        // Initialize market with positions
        init_market(ASK, econia, user_0, user_1, user_2, user_3);
        // Attempt invalid market buy
        submit_market_buy<BCT, QCT, E1>(econia, @Econia, 500, 1);
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    #[expected_failure(abort_code = 4)]
    /// Verify failure when market buy with no quote coins allocated
    public entry fun submit_market_order_failure_quote_spend_0(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        // Initialize market with positions
        init_market(ASK, econia, user_0, user_1, user_2, user_3);
        // Attempt invalid market buy
        submit_market_buy<BCT, QCT, E1>(user_0, @Econia, 500, 0);
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    #[expected_failure(abort_code = 3)]
    /// Verify failure when market buy with no requested order size
    public entry fun submit_market_order_failure_size_0(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        // Initialize market with positions
        init_market(ASK, econia, user_0, user_1, user_2, user_3);
        // Attempt invalid market buy
        submit_market_buy<BCT, QCT, E1>(user_0, @Econia, 0, 500);
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    #[expected_failure(abort_code = 0)]
    /// Verify failure when no order book at host address
    public entry fun submit_market_order_failure_wrong_host(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        // Initialize market with positions
        init_market(ASK, econia, user_0, user_1, user_2, user_3);
        // Attempt invalid market buy
        submit_market_buy<BCT, QCT, E1>(user_0, @TestUser, 500, 1);
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    /// Verify swap values for clearing out two positions on book
    public entry fun swap_buy_success(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        let side = ASK; // Define book side market order fills against
        // Define number of parcels to buy in swap
        let parcels_to_buy = USER_1_ASK_SIZE + USER_2_ASK_SIZE;
        // Define max quote coins to spend
        let max_quote_to_spend =
            USER_1_ASK_PRICE * USER_1_ASK_SIZE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE;
        // Calculate base coins user 0 ends with
        let user_0_end_base = USER_0_START_BASE + SCALE_FACTOR *
            (USER_1_ASK_SIZE + USER_2_ASK_SIZE);
        // Calculate quote coins user 0 ends with
        let user_0_end_quote = USER_0_START_QUOTE -
            USER_1_ASK_PRICE * USER_1_ASK_SIZE -
            USER_2_ASK_PRICE * USER_2_ASK_SIZE;
        // Initialize market with positions
        init_market(side, econia, user_0, user_1, user_2, user_3);
        // Withdraw required collateral into user's coin stores, since
        // swap function takes it from there
        collateral_withdraw<BCT, QCT, E1>(
            user_0, 0, max_quote_to_spend, &orders_cap());
        // Fill the market order of given size
        swap_buy<BCT, QCT, E1>(user_0, @Econia,
            parcels_to_buy, max_quote_to_spend);
        // Get interpreted collateral field values for user 0
        let (u_0_b_available, u_0_b_coins, u_0_q_available, u_0_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser);
        // Assert correct collateral field values
        assert!(u_0_b_coins == 0, 0);
        assert!(u_0_b_available == 0, 0);
        assert!(u_0_q_coins == 0, 0);
        assert!(u_0_q_available == 0, 0);
        // Assert correct balances in coin store
        assert!(coin_store_balance<BCT>(@TestUser) == user_0_end_base, 0);
        assert!(coin_store_balance<QCT>(@TestUser) == user_0_end_quote, 0);
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3,
        user_4 = @TestUser4
    )]
    /// Verify swap values for clearing out two positions on book, with
    /// user who has only quote coin store initialized
    public entry fun swap_buy_success_init(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer,
        user_4: &signer
    ) {
        let side = ASK; // Define book side market order fills against
        // Define number of parcels to buy in swap
        let parcels_to_buy = USER_1_ASK_SIZE + USER_2_ASK_SIZE;
        // Define max quote coins to spend
        let max_quote_to_spend =
            USER_1_ASK_PRICE * USER_1_ASK_SIZE +
            USER_2_ASK_PRICE * USER_2_ASK_SIZE;
        // Calculate base coins user 4 ends with
        let user_4_end_base = SCALE_FACTOR *
            (USER_1_ASK_SIZE + USER_2_ASK_SIZE);
        // Initialize market with positions
        init_market(side, econia, user_0, user_1, user_2, user_3);
        // Initialize Account resource under uninitialized user
        create_account(@TestUser4);
        // Register uninitialized user with quote coin store
        register_coin_store<QCT>(user_4);
        // Mint quote coins to user's coin store
        mint_qct_to(@TestUser4, max_quote_to_spend);
        // Fill the market order of given size
        swap_buy<BCT, QCT, E1>(user_4, @Econia,
            parcels_to_buy, max_quote_to_spend);
        // Get interpreted collateral field values for user 4
        let (u_4_b_available, u_4_b_coins, u_4_q_available, u_4_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser4);
        // Assert correct collateral field values
        assert!(u_4_b_coins == 0, 0);
        assert!(u_4_b_available == 0, 0);
        assert!(u_4_q_coins == 0, 0);
        assert!(u_4_q_available == 0, 0);
        // Assert correct balances in coin store
        assert!(coin_store_balance<BCT>(@TestUser4) == user_4_end_base, 0);
        assert!(coin_store_balance<QCT>(@TestUser4) == 0, 0);
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3
    )]
    /// Verify swap values for clearing out two positions on book
    public entry fun swap_sell_success(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer
    ) {
        let side = BID; // Define book side market order fills against
        // Define number of parcels to sell in swap
        let parcels_to_sell = USER_1_BID_SIZE + USER_2_BID_SIZE;
        // Calculate base coins user 0 ends with
        let user_0_end_base = USER_0_START_BASE - SCALE_FACTOR *
            (USER_1_BID_SIZE + USER_2_BID_SIZE);
        // Calculate quote coins user 0 ends with
        let user_0_end_quote = USER_0_START_QUOTE +
            USER_1_BID_PRICE * USER_1_BID_SIZE +
            USER_2_BID_PRICE * USER_2_BID_SIZE;
        // Initialize market with positions
        init_market(side, econia, user_0, user_1, user_2, user_3);
        // Withdraw required collateral into user's coin stores, since
        // swap function takes it from there
        collateral_withdraw<BCT, QCT, E1>(
            user_0, SCALE_FACTOR * parcels_to_sell, 0, &orders_cap());
        // Fill the market order of given size
        swap_sell<BCT, QCT, E1>(user_0, @Econia, parcels_to_sell);
        // Get interpreted collateral field values for user 0
        let (u_0_b_available, u_0_b_coins, u_0_q_available, u_0_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser);
        // Assert correct collateral field values
        assert!(u_0_b_coins == 0, 0);
        assert!(u_0_b_available == 0, 0);
        assert!(u_0_q_coins == 0, 0);
        assert!(u_0_q_available == 0, 0);
        // Assert correct balances in coin store
        assert!(coin_store_balance<BCT>(@TestUser) == user_0_end_base, 0);
        assert!(coin_store_balance<QCT>(@TestUser) == user_0_end_quote, 0);
    }

    #[test(
        econia = @Econia,
        user_0 = @TestUser,
        user_1 = @TestUser1,
        user_2 = @TestUser2,
        user_3 = @TestUser3,
        user_4 = @TestUser4
    )]
    /// Verify swap values for clearing out two positions on book, with
    /// user who has only base coin store initialized
    public entry fun swap_sell_success_init(
        econia: &signer,
        user_0: &signer,
        user_1: &signer,
        user_2: &signer,
        user_3: &signer,
        user_4: &signer
    ) {
        let side = BID; // Define book side market order fills against
        // Define number of parcels to sell in swap
        let parcels_to_sell = USER_1_BID_SIZE + USER_2_BID_SIZE;
        // Calculate quote coins user 4 ends with
        let user_4_end_quote = USER_1_BID_PRICE * USER_1_BID_SIZE +
            USER_2_BID_PRICE * USER_2_BID_SIZE;
        // Initialize market with positions
        init_market(side, econia, user_0, user_1, user_2, user_3);
        // Initialize Account resource under uninitialized user
        create_account(@TestUser4);
        // Register uninitialized user with base coin store
        register_coin_store<BCT>(user_4);
        // Mint base coins to user's coin store
        mint_bct_to(@TestUser4, SCALE_FACTOR * parcels_to_sell);
        // Fill the market order of given size
        swap_sell<BCT, QCT, E1>(user_4, @Econia, parcels_to_sell);
        // Get interpreted collateral field values for user 4
        let (u_4_b_available, u_4_b_coins, u_4_q_available, u_4_q_coins) =
                check_collateral<BCT, QCT, E1>(@TestUser4);
        // Assert correct collateral field values
        assert!(u_4_b_coins == 0, 0);
        assert!(u_4_b_available == 0, 0);
        assert!(u_4_q_coins == 0, 0);
        assert!(u_4_q_available == 0, 0);
        // Assert correct balances in coin store
        assert!(coin_store_balance<BCT>(@TestUser4) == 0, 0);
        assert!(coin_store_balance<QCT>(@TestUser4) == user_4_end_quote, 0);
    }

    // Tests >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
}