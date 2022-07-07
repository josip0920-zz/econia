/// User-facing trading functionality
module Econia::User {

    // Uses >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    use AptosFramework::Account::{
        get_sequence_number as a_g_s_n
    };

    use AptosFramework::Coin::{
        Coin as C,
        deposit as c_d,
        extract as c_e,
        merge as c_m,
        withdraw as c_w,
        zero as c_z
    };

    use Econia::Book::{
        add_ask as b_a_a,
        add_bid as b_a_b,
        exists_book as b_e_b
    };

    use Econia::Caps::{
        orders_f_c as c_o_f_c,
        book_f_c as c_b_f_c
    };

    use Econia::ID::{
        id_a as id_a,
        id_b as id_b
    };

    use Econia::Orders::{
        add_ask as o_a_a,
        add_bid as o_a_b,
        exists_orders as o_e_o,
        init_orders as o_i_o
    };

    use Econia::Registry::{
        is_registered as r_i_r,
        scale_factor as r_s_f
    };

    use Econia::Version::{
        get_v_n as v_g_v_n
    };

    use Std::Signer::{
        address_of as s_a_o
    };

    // Uses <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Test-only uses >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[test_only]
    use AptosFramework::Account::{
        create_account as a_c_a,
        increment_sequence_number as a_i_s_n,
        set_sequence_number as a_s_s_n
    };

    #[test_only]
    use AptosFramework::Coin::{
        balance as c_b,
        register as c_r,
        value as c_v
    };

    #[test_only]
    use Econia::Init::init_econia;

    #[test_only]
    use Econia::Orders::{
        scale_factor as o_s_f
    };

    #[test_only]
    use Econia::Registry::{
        BCT,
        E0,
        E1,
        mint_bct_to as r_m_bct_to,
        mint_qct_to as r_m_qct_to,
        QCT,
        register_test_market as r_r_t_m,
        register_scaled_test_market as r_r_s_t_m
    };

    // Test-only uses <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Structs >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Order collateral for a given market
    struct OC<phantom B, phantom Q, phantom E> has key {
        /// Indivisible subunits of base coins available to withdraw
        b_a: u64,
        /// Base coins held as collateral
        b_c: C<B>,
        /// Indivisible subunits of quote coins available to withdraw
        q_a: u64,
        /// Quote coins held as collateral
        q_c: C<Q>
    }

    /// Counter for sequence number of last monitored Econia transaction
    struct SC has key {
        i: u64
    }

    // Structs <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Error codes >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// When order collateral container already exists
    const E_O_C_EXISTS: u64 = 0;
    /// When no corresponding market
    const E_NO_MARKET: u64 = 1;
    /// When open orders container already exists
    const E_O_O_EXISTS: u64 = 2;
    /// When sequence number counter already exists for user
    const E_S_C_EXISTS: u64 = 3;
    /// When sequence number counter does not exist for user
    const E_NO_S_C: u64 = 4;
    /// When invalid sequence number for current transaction
    const E_INVALID_S_N: u64 = 5;
    /// When no order collateral container
    const E_NO_O_C: u64 = 6;
    /// When no transfer of funds indicated
    const E_NO_TRANSFER: u64 = 7;
    /// When attempting to withdraw more than is available
    const E_WITHDRAW_TOO_MUCH: u64 = 8;
    /// When not enough collateral for an operation
    const E_NOT_ENOUGH_COLLATERAL: u64 = 9;
    /// When an attempted limit order crosses the spread
    const E_CROSSES_SPREAD: u64 = 10;

    // Error codes <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Constants >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Ask flag
    const ASK: bool = true;
    /// Bid flag
    const BID: bool = false;

    // Constants <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Public script functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Deposit `b_val` base coin and `q_val` quote coin into `user`'s
    /// `OC`, from their `AptosFramework::Coin::CoinStore`
    public(script) fun deposit<B, Q, E>(
        user: &signer,
        b_val: u64,
        q_val: u64
    ) acquires OC, SC {
        let addr = s_a_o(user); // Get user address
        // Assert user has order collateral container
        assert!(exists<OC<B, Q, E>>(addr), E_NO_O_C);
        // Assert user actually attempting to deposit
        assert!(b_val > 0 || q_val > 0, E_NO_TRANSFER);
        // Borrow mutable reference to user collateral container
        let o_c = borrow_global_mut<OC<B, Q, E>>(addr);
        if (b_val > 0) { // If base coin to be deposited
            c_m<B>(&mut o_c.b_c, c_w<B>(user, b_val)); // Deposit it
            o_c.b_a = o_c.b_a + b_val; // Increment available base coin
        };
        if (q_val > 0) { // If quote coin to be deposited
            c_m<Q>(&mut o_c.q_c, c_w<Q>(user, q_val)); // Deposit it
            o_c.q_a = o_c.q_a + q_val; // Increment available quote coin
        };
        update_s_c(user); // Update user sequence counter
    }

    /// Initialize a user with `Econia::Orders::OO` and `OC` for market
    /// with base coin type `B`, quote coin type `Q`, and scale exponent
    /// `E`, aborting if no such market or if containers already
    /// initialized for market
    public(script) fun init_containers<B, Q, E>(
        user: &signer
    ) {
        assert!(r_i_r<B, Q, E>(), E_NO_MARKET); // Assert market exists
        let user_addr = s_a_o(user); // Get user address
        // Assert user does not already have collateral container
        assert!(!exists<OC<B, Q, E>>(user_addr), E_O_C_EXISTS);
        // Assert user does not already have open orders container
        assert!(!o_e_o<B, Q, E>(user_addr), E_O_O_EXISTS);
        // Pack empty collateral container
        let o_c = OC<B, Q, E>{b_c: c_z<B>(), b_a: 0, q_c: c_z<Q>(), q_a: 0};
        move_to<OC<B, Q, E>>(user, o_c); // Move to user account
        // Initialize empty open orders container under user account
        o_i_o<B, Q, E>(user, r_s_f<E>(), &c_o_f_c());
    }

    /// Initialize an `SC` with the sequence number of the initializing
    /// transaction, aborting if one already exists
    public(script) fun init_user(
        user: &signer
    ) {
        let user_addr = s_a_o(user); // Get user address
        // Assert user has not already initialized a sequence counter
        assert!(!exists<SC>(user_addr), E_S_C_EXISTS);
        // Initialize sequence counter with user's sequence number
        move_to<SC>(user, SC{i: a_g_s_n(user_addr)});
    }

    /// Wrapped `submit_limit_order()` call for `ASK`
    public(script) fun submit_ask<B, Q, E>(
        user: &signer,
        host: address,
        price: u64,
        size: u64
    ) acquires OC, SC {
        submit_limit_order<B, Q, E>(user, host, ASK, price, size);
    }

    /// Wrapped `submit_limit_order()` call for `BID`
    public(script) fun submit_bid<B, Q, E>(
        user: &signer,
        host: address,
        price: u64,
        size: u64
    ) acquires OC, SC {
        submit_limit_order<B, Q, E>(user, host, BID, price, size);
    }

    /// Withdraw `b_val` base coin and `q_val` quote coin from `user`'s
    /// `OC`, into their `AptosFramework::Coin::CoinStore`
    public(script) fun withdraw<B, Q, E>(
        user: &signer,
        b_val: u64,
        q_val: u64
    ) acquires OC, SC {
        let addr = s_a_o(user); // Get user address
        // Assert user has order collateral container
        assert!(exists<OC<B, Q, E>>(addr), E_NO_O_C);
        // Assert user actually attempting to withdraw
        assert!(b_val > 0 || q_val > 0, E_NO_TRANSFER);
        // Borrow mutable reference to user collateral container
        let o_c = borrow_global_mut<OC<B, Q, E>>(addr);
        if (b_val > 0) { // If base coin to be withdrawn
            // Assert not trying to withdraw more than available
            assert!(!(b_val > o_c.b_a), E_WITHDRAW_TOO_MUCH);
            // Withdraw from order collateral, deposit to coin store
            c_d<B>(addr, c_e<B>(&mut o_c.b_c, b_val));
            o_c.b_a = o_c.b_a - b_val; // Update available amount
        };
        if (q_val > 0) { // If quote coin to be withdrawn
            // Assert not trying to withdraw more than available
            assert!(!(q_val > o_c.q_a), E_WITHDRAW_TOO_MUCH);
            // Withdraw from order collateral, deposit to coin store
            c_d<Q>(addr, c_e<Q>(&mut o_c.q_c, q_val));
            o_c.q_a = o_c.q_a - q_val; // Update available amount
        };
        update_s_c(user); // Update user sequence counter
    }

    // Public script functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Private functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Initialize order collateral container for given user, aborting
    /// if already initialized
    fun init_o_c<B, Q, E>(
        user: &signer,
    ) {
        // Assert user does not already have order collateral for market
        assert!(!exists<OC<B, Q, E>>(s_a_o(user)), E_O_C_EXISTS);
        // Assert given market has actually been registered
        assert!(r_i_r<B, Q, E>(), E_NO_MARKET);
        // Pack empty order collateral container
        let o_c = OC<B, Q, E>{b_c: c_z<B>(), b_a: 0, q_c: c_z<Q>(), q_a: 0};
        move_to<OC<B, Q, E>>(user, o_c); // Move to user account
    }

    /// Submit limit order for market `<B, Q, E>`
    ///
    /// # Parameters
    /// * `user`: User submitting a limit order
    /// * `host`: The market host (See `Econia::Registry`)
    /// * `side`: `ASK` or `BID`
    /// * `price`: Scaled integer price (see `Econia::ID`)
    /// * `size`: Unscaled order size (see `Econia::Orders`), in base
    ///   coin subunits
    ///
    /// # Abort conditions
    /// * If no such market exists at host address
    /// * If user does not have order collateral container for market
    /// * If user does not have enough collateral
    /// * If placing an order would cross the spread (temporary)
    fun submit_limit_order<B, Q, E>(
        user: &signer,
        host: address,
        side: bool,
        price: u64,
        size: u64
    ) acquires OC, SC {
        update_s_c(user); // Update user sequence counter
        // Assert market exists at given host address
        assert!(b_e_b<B, Q, E>(host), E_NO_MARKET);
        let addr = s_a_o(user); // Get user address
        // Assert user has order collateral container
        assert!(exists<OC<B, Q, E>>(addr), E_NO_O_C);
        // Borrow mutable reference to user's order collateral container
        let o_c = borrow_global_mut<OC<B, Q, E>>(addr);
        let v_n = v_g_v_n(); // Get transaction version number
        let c_s: bool; // Define flag for if order crosses the spread
        if (side == ASK) { // If limit order is an ask
            let id = id_a(price, v_n); // Get corresponding order id
            // Verify and add to user's open orders, storing scaled size
            let (scaled_size, _) =
                o_a_a<B, Q, E>(addr, id, price, size, &c_o_f_c());
            // Assert user has enough base coins held as collateral
            assert!(!(size > o_c.b_a), E_NOT_ENOUGH_COLLATERAL);
            // Decrement amount of base coins available for withdraw
            o_c.b_a = o_c.b_a - size;
            // Try adding to order book, storing crossed spread flag
            c_s =
                b_a_a<B, Q, E>(host, addr, id, price, scaled_size, &c_b_f_c());
        } else { // If limit order is a bid
            let id = id_b(price, v_n); // Get corresponding order id
            // Verify and add to user's open orders, storing scaled size
            // and amount of quote coins needed to fill the order
            let (scaled_size, fill_amount) =
                o_a_b<B, Q, E>(addr, id, price, size, &c_o_f_c());
            // Assert user has enough quote coins held as collateral
            assert!(!(fill_amount > o_c.q_a), E_NOT_ENOUGH_COLLATERAL);
            // Decrement amount of base coins available for withdraw
            o_c.q_a = o_c.q_a - fill_amount;
            // Try adding to order book, storing crossed spread flag
            c_s =
                b_a_b<B, Q, E>(host, addr, id, price, scaled_size, &c_b_f_c());
        };
        assert!(!c_s, E_CROSSES_SPREAD); // Assert uncrossed spread
    }

    /// Update sequence counter for user `u` with the sequence number of
    /// the current transaction, aborting if user does not have an
    /// initialized sequence counter or if sequence number is not
    /// greater than the number indicated by the user's `SC`
    fun update_s_c(
        u: &signer,
    ) acquires SC {
        let user_addr = s_a_o(u); // Get user address
        // Assert user has already initialized a sequence counter
        assert!(exists<SC>(user_addr), E_NO_S_C);
        // Borrow mutable reference to user's sequence counter
        let s_c = borrow_global_mut<SC>(user_addr);
        let s_n = a_g_s_n(user_addr); // Get current sequence number
        // Assert new sequence number greater than that of counter
        assert!(s_n > s_c.i, E_INVALID_S_N);
        s_c.i = s_n; // Update counter with current sequence number
    }

    // Private functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Test-only functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[test_only]
    /// Initialize a user with containers for a test market
    public(script) fun init_test_market_user(
        econia: &signer,
        user: &signer
    ) {
        init_econia(econia); // Initialize Econia core resources
        r_r_t_m(econia); // Register test market
        a_c_a(s_a_o(user)); // Initialize Account resource
        init_user(user); // Initialize user
        init_containers<BCT, QCT, E0>(user); // Initialize containers
        c_r<BCT>(user); // Register user with base coin store
        c_r<QCT>(user); // Register user with quote coin store
    }

    #[test_only]
    /// Initialize test market with scale exponent `E` hosted by Econia,
    /// funding a test user with `b_c` base coins and `q_c` quote coins
    public(script) fun init_test_scaled_market_funded_user<E>(
        econia: &signer,
        user: &signer,
        b_c: u64,
        q_c: u64
    ) acquires OC, SC {
        init_econia(econia); // Initialize Econia core resources
        r_r_s_t_m<E>(econia); // Register scaled test market
        a_c_a(s_a_o(user)); // Initialize Account resource
        init_user(user); // Initialize user
        let user_addr = s_a_o(user); // Get user address
        a_i_s_n(user_addr); // Increment mock sequence number
        init_containers<BCT, QCT, E>(user); // Initialize containers
        a_i_s_n(user_addr); // Increment mock sequence number
        c_r<BCT>(user); // Register user with base coin store
        c_r<QCT>(user); // Register user with quote coin store
        r_m_bct_to(user_addr, b_c); // Mint base coins to user
        r_m_qct_to(user_addr, q_c); // Mint quote coins to user
        deposit<BCT, QCT, E>(user, b_c, q_c); // Deposit all coins
        a_i_s_n(user_addr); // Increment mock sequence number
    }

    // Test-only functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Tests >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[test(
        econia = @Econia,
        user = @TestUser
    )]
    #[expected_failure(abort_code = 7)]
    /// Verify failure for no deposit indicated
    public(script) fun deposit_failure_no_deposit(
        econia: &signer,
        user: &signer
    ) acquires OC, SC {
        init_test_market_user(econia, user); // Init test market, user
        deposit<BCT, QCT, E0>(user, 0, 0); // Attempt invalid deposit
    }

    #[test(user = @TestUser)]
    #[expected_failure(abort_code = 6)]
    /// Verify failure for no order collateral container initialized
    public(script) fun deposit_failure_no_o_c(
        user: &signer
    ) acquires OC, SC {
        deposit<BCT, QCT, E0>(user, 1, 2); // Attempt invalid deposit
    }

    #[test(
        econia = @Econia,
        user = @TestUser
    )]
    /// Verify successful collateral deposits
    public(script) fun deposit_success(
        econia: &signer,
        user: &signer
    ) acquires OC, SC {
        init_test_market_user(econia, user); // Init test market, user
        let addr = s_a_o(user); // Get user address
        r_m_bct_to(addr, 100); // Mint 100 base coins to user
        r_m_qct_to(addr, 200); // Mint 200 base coins to user
        a_i_s_n(addr); // Increment mock sequence number
        deposit<BCT, QCT, E0>(user, 1, 0); // Deposit one base coin
        // Assert correct coin store balances
        assert!(c_b<BCT>(addr) == 99 && c_b<QCT>(addr) == 200, 0);
        // Borrow immutable reference to user's order collateral
        let o_c = borrow_global<OC<BCT, QCT, E0>>(addr);
        // Assert collateral holdings update correctly
        assert!(c_v<BCT>(&o_c.b_c) == 1 && c_v<QCT>(&o_c.q_c) == 0, 1);
        // Assert withdraw availability updates correctly
        assert!(o_c.b_a == 1 && o_c.q_a == 0, 2);
        a_i_s_n(addr); // Increment mock sequence number
        deposit<BCT, QCT, E0>(user, 0, 2); // Deposit two quote coin
        // Assert correct coin store balances
        assert!(c_b<BCT>(addr) == 99 && c_b<QCT>(addr) == 198, 3);
        // Borrow immutable reference to user's order collateral
        let o_c = borrow_global<OC<BCT, QCT, E0>>(addr);
        // Assert collateral holdings update correctly
        assert!(c_v<BCT>(&o_c.b_c) == 1 && c_v<QCT>(&o_c.q_c) == 2, 4);
        // Assert withdraw availability updates correctly
        assert!(o_c.b_a == 1 && o_c.q_a == 2, 5);
        a_i_s_n(addr); // Increment mock sequence number
        deposit<BCT, QCT, E0>(user, 5, 5); // Deposit 5 of each coin
        // Assert correct coin store balances
        assert!(c_b<BCT>(addr) == 94 && c_b<QCT>(addr) == 193, 6);
        // Borrow immutable reference to user's order collateral
        let o_c = borrow_global<OC<BCT, QCT, E0>>(addr);
        // Assert collateral holdings update correctly
        assert!(c_v<BCT>(&o_c.b_c) == 6 && c_v<QCT>(&o_c.q_c) == 7, 7);
        // Assert withdraw availability updates correctly
        assert!(o_c.b_a == 6 && o_c.q_a == 7, 8);
    }

    #[test(
        econia = @Econia,
        user = @TestUser
    )]
    #[expected_failure(abort_code = 0)]
    /// Verify failure for attempting to re-initialize order collateral
    public(script) fun init_o_c_failure_exists(
        econia: &signer,
        user: &signer
    ) {
        init_econia(econia); // Initialize Econia core account resources
        r_r_t_m(econia); // Register test market
        init_o_c<BCT, QCT, E0>(user); // Initialize order collateral
        init_o_c<BCT, QCT, E0>(user); // Attempt invalid re-init
    }

    #[test(user = @TestUser)]
    #[expected_failure(abort_code = 1)]
    /// Verify failure for attempting to initialize order collateral for
    /// non-existent market
    fun init_o_c_failure_no_market(
        user: &signer
    ) {
        init_o_c<BCT, QCT, E0>(user); // Attempt invalid intialization
    }

    #[test(
        econia = @Econia,
        user = @TestUser
    )]
    /// Verify successful initialization of order collateral
    public(script) fun init_o_c_success(
        econia: &signer,
        user: &signer
    ) acquires OC {
        init_econia(econia); // Initialize Econia core account resources
        r_r_t_m(econia); // Register test market
        init_o_c<BCT, QCT, E0>(user); // Initialize order collateral
        // Borrow immutable reference to order collateral container
        let o_c = borrow_global<OC<BCT, QCT, E0>>(s_a_o(user));
        // Assert no base coins or quote coins in collateral container
        assert!(c_v(&o_c.b_c) == 0 && c_v(&o_c.q_c) == 0, 0);
        // Assert no base coins or quote coins marked available
        assert!(o_c.b_a == 0 && o_c.q_a == 0, 1);
    }

    #[test(
        econia = @Econia,
        user = @TestUser
    )]
    #[expected_failure(abort_code = 0)]
    /// Verify failure for user having order collateral container
    public(script) fun init_containers_failure_has_o_c(
        econia: &signer,
        user: &signer
    ) {
        init_econia(econia); // Initialize Econia core account resources
        r_r_t_m(econia); // Register test market
        init_o_c<BCT, QCT, E0>(user); // Init order collateral container
        init_containers<BCT, QCT, E0>(user); // Attempt invalid init
    }

    #[test(
        econia = @Econia,
        user = @TestUser
    )]
    #[expected_failure(abort_code = 2)]
    /// Verify failure for user already having open orders container
    public(script) fun init_containers_failure_has_o_o(
        econia: &signer,
        user: &signer
    ) {
        init_econia(econia); // Initialize Econia core account resources
        r_r_t_m(econia); // Register test market
        // Initialize empty open orders container under user account
        o_i_o<BCT, QCT, E0>(user, r_s_f<E0>(), &c_o_f_c());
        init_containers<BCT, QCT, E0>(user); // Attempt invalid init
    }

    #[test(user = @TestUser)]
    #[expected_failure(abort_code = 1)]
    /// Verify failure for unregistered market
    public(script) fun init_containers_failure_no_market(
        user: &signer
    ) {
        init_containers<BCT, QCT, E0>(user); // Attempt invalid init
    }

    #[test(
        econia = @Econia,
        user = @TestUser
    )]

    /// Verify successful user initialization
    public(script) fun init_containers_success(
        econia: &signer,
        user: &signer
    ) acquires OC {
        init_econia(econia); // Initalize Econia core account resources
        r_r_t_m(econia); // Register test market
        // Init test market user containers
        init_containers<BCT, QCT, E0>(user);
        let user_addr = s_a_o(user); // Get user address
        // Borrow immutable reference to order collateral container
        let o_c = borrow_global<OC<BCT, QCT, E0>>(user_addr);
        // Assert no base coins or quote coins in collateral container
        assert!(c_v(&o_c.b_c) == 0 && c_v(&o_c.q_c) == 0, 0);
        // Assert no base coins or quote coins marked available
        assert!(o_c.b_a == 0 && o_c.q_a == 0, 1);
        // Assert open orders exists and has correct scale factor
        assert!(o_s_f<BCT, QCT, E0>(user_addr) == r_s_f<E0>(), 0);
    }

    #[test(user = @TestUser)]
    #[expected_failure(abort_code = 3)]
    /// Verify failure for attempted re-initialization
    public(script) fun init_user_failure(
        user: &signer
    ) {
        a_c_a(s_a_o(user)); // Initialize Account resource
        init_user(user); // Initialize sequence counter for user
        init_user(user); // Attempt invalid re-initialization
    }

    #[test(user = @TestUser)]
    /// Verify successful initialization
    public(script) fun init_user_success(
        user: &signer
    ) {
        let user_addr = s_a_o(user); // Get user address
        a_c_a(user_addr); // Initialize Account resource
        init_user(user); // Initialize sequence counter for user
        // Assert sequence counter initializes to user sequence number
        assert!(a_g_s_n(user_addr) == 0, 0);
    }

    #[test(
        econia = @Econia,
        user = @TestUser
    )]
    #[expected_failure(abort_code = 9)]
    /// Verify failure for user having insufficient collateral
    public(script) fun submit_ask_failure_collateral(
        econia: &signer,
        user: &signer
    ) acquires OC, SC {
        // Initialize test market with scale exponent 1, fund user with
        // 100 base coins and 200 quote coins
        init_test_scaled_market_funded_user<E1>(econia, user, 100, 200);
        // Attempt submitting invalid ask of size 110 base coins
        submit_ask<BCT, QCT, E1>(user, s_a_o(econia), 1, 110);
    }

    #[test(
        econia = @Econia,
        user = @TestUser
    )]
    #[expected_failure(abort_code = 10)]
    /// Verify failure for user placing order that crosses spread
    public(script) fun submit_ask_failure_crossed_spread(
        econia: &signer,
        user: &signer
    ) acquires OC, SC {
        // Initialize test market with scale exponent 0, fund user with
        // 100 base coins and 200 quote coins
        init_test_scaled_market_funded_user<E0>(econia, user, 100, 200);
        let host = s_a_o(econia); // Get market host address
        // Submit bid of price 5, size 2
        submit_bid<BCT, QCT, E0>(user, host, 5, 2);
        let user_addr = s_a_o(user); // Get user address
        a_i_s_n(user_addr); // Increment mock sequence number
        // Submit ask of price 7, size 3
        submit_ask<BCT, QCT, E0>(user, host, 7, 3);
        a_i_s_n(user_addr); // Increment mock sequence number
        // Submit invalid ask of price 4, size 4, crossing the spread
        submit_ask<BCT, QCT, E0>(user, host, 4, 4);
    }

    #[test(
        econia = @Econia,
        user = @TestUser
    )]
    #[expected_failure(abort_code = 9)]
    /// Verify failure for user having insufficient collateral
    public(script) fun submit_bid_failure_collateral(
        econia: &signer,
        user: &signer
    ) acquires OC, SC {
        // Initialize test market with scale exponent 1, fund user with
        // 100 base coins and 200 quote coins
        init_test_scaled_market_funded_user<E1>(econia, user, 100, 200);
        // Attempt submitting invalid bid for 10 base coins at a scaled
        // price of 201 (201 quote coins for 10 scaled coins)
        submit_bid<BCT, QCT, E1>(user, s_a_o(econia), 201, 10);
    }

    #[test(
        econia = @Econia,
        user = @TestUser
    )]
    #[expected_failure(abort_code = 10)]
    /// Verify failure for user placing order that crosses spread
    public(script) fun submit_bid_failure_crossed_spread(
        econia: &signer,
        user: &signer
    ) acquires OC, SC {
        // Initialize test market with scale exponent 0, fund user with
        // 100 base coins and 200 quote coins
        init_test_scaled_market_funded_user<E0>(econia, user, 100, 200);
        let host = s_a_o(econia); // Get market host address
        // Submit bid of price 5, size 2
        submit_bid<BCT, QCT, E0>(user, host, 5, 2);
        let user_addr = s_a_o(user); // Get user address
        a_i_s_n(user_addr); // Increment mock sequence number
        // Submit ask of price 7, size 3
        submit_ask<BCT, QCT, E0>(user, host, 7, 3);
        a_i_s_n(user_addr); // Increment mock sequence number
        // Submit invalid bid of price 8, size 4, crossing the spread
        submit_bid<BCT, QCT, E0>(user, host, 8, 4);
    }

    #[test(user = @TestUser)]
    #[expected_failure(abort_code = 1)]
    /// Verify failure for no such market
    public(script) fun submit_limit_order_failure_no_market(
        user: &signer
    ) acquires OC, SC {
        let user_addr = s_a_o(user); // Get user address
        a_c_a(user_addr); // Initialize Account resource
        init_user(user); // Initialize sequence counter for user
        a_i_s_n(user_addr); // Increment mock sequence number
        // Attempt invalid limit order
        submit_ask<BCT, QCT, E0>(user, s_a_o(user), 1, 1);
    }

    #[test(
        econia = @Econia,
        user = @TestUser
    )]
    #[expected_failure(abort_code = 6)]
    /// Verify failure for user not having order collateral container
    public(script) fun submit_limit_order_failure_no_o_c(
        econia: &signer,
        user: &signer
    ) acquires OC, SC {
        init_econia(econia); // Initialize Econia core resources
        r_r_t_m(econia); // Register test market
        let user_addr = s_a_o(user); // Get user address
        a_c_a(user_addr); // Initialize Account resource
        init_user(user); // Initialize sequence counter for user
        a_i_s_n(user_addr); // Increment mock sequence number
        // Attempt invalid limit order
        submit_bid<BCT, QCT, E0>(user, s_a_o(econia), 1, 1);
    }

    #[test(user = @TestUser)]
    #[expected_failure(abort_code = 4)]
    /// Verify failure for user not having initialized counter
    fun update_s_c_failure_no_s_c(
        user: &signer
    ) acquires SC {
        update_s_c(user); // Attempt invalid update
    }

    #[test(user = @TestUser)]
    #[expected_failure(abort_code = 5)]
    /// Verify failure for trying to update twice in same transaction
    public(script) fun update_s_c_failure_same_s_n(
        user: &signer
    ) acquires SC {
        let user_addr = s_a_o(user); // Get user address
        a_c_a(user_addr); // Initialize Account resource
        init_user(user); // Initialize sequence counter for user
        // Attempt invalid update during same transaction as init
        update_s_c(user);
    }

    #[test(user = @TestUser)]
    /// Verify successful update for arbitrary (valid) sequence number
    public(script) fun update_s_c_success(
        user: &signer
    ) acquires SC {
        let user_addr = s_a_o(user); // Get user address
        a_c_a(user_addr); // Initialize Account resource
        init_user(user); // Initialize sequence counter for user
        a_s_s_n(user_addr, 10); // Set mock sequence number
        update_s_c(user); // Execute valid counter update
        // Assert sequence counter updated correctly
        assert!(borrow_global<SC>(user_addr).i == 10, 0);
    }

    #[test(
        econia = @Econia,
        user = @TestUser
    )]
    #[expected_failure(abort_code = 8)]
    /// Verify failure for attempting to withdraw to many base coins
    public(script) fun withdraw_failure_excess_bct(
        econia: &signer,
        user: &signer
    ) acquires OC, SC {
        init_test_market_user(econia, user); // Init test market, user
        let addr = s_a_o(user); // Get user address
        r_m_bct_to(addr, 100); // Mint 100 base coins to user
        a_i_s_n(addr); // Increment mock sequence number
        deposit<BCT, QCT, E0>(user, 50, 0); // Deposit collateral
        a_i_s_n(addr); // Increment mock sequence number
        withdraw<BCT, QCT, E0>(user, 51, 0); // Attempt invalid withdraw
    }

    #[test(
        econia = @Econia,
        user = @TestUser
    )]
    #[expected_failure(abort_code = 8)]
    /// Verify failure for attempting to withdraw to many quote coins
    public(script) fun withdraw_failure_excess_qct(
        econia: &signer,
        user: &signer
    ) acquires OC, SC {
        init_test_market_user(econia, user); // Init test market, user
        let addr = s_a_o(user); // Get user address
        r_m_qct_to(addr, 100); // Mint 100 quote coins to user
        a_i_s_n(addr); // Increment mock sequence number
        deposit<BCT, QCT, E0>(user, 0, 50); // Deposit collateral
        a_i_s_n(addr); // Increment mock sequence number
        withdraw<BCT, QCT, E0>(user, 0, 51); // Attempt invalid withdraw
    }

    #[test(user = @TestUser)]
    #[expected_failure(abort_code = 6)]
    /// Verify failure for no order collateral container initialized
    public(script) fun withdraw_failure_no_o_c(
        user: &signer
    ) acquires OC, SC {
        withdraw<BCT, QCT, E0>(user, 1, 2); // Attempt invalid withdraw
    }

    #[test(
        econia = @Econia,
        user = @TestUser
    )]
    #[expected_failure(abort_code = 7)]
    /// Verify failure for no withdraw indicated
    public(script) fun withdraw_failure_no_withdraw(
        econia: &signer,
        user: &signer
    ) acquires OC, SC {
        init_test_market_user(econia, user); // Init test market, user
        withdraw<BCT, QCT, E0>(user, 0, 0); // Attempt invalid withdraw
    }

    #[test(
        econia = @Econia,
        user = @TestUser
    )]
    /// Verify successful collateral withdrawals
    public(script) fun withdraw_success(
        econia: &signer,
        user: &signer
    ) acquires OC, SC {
        init_test_market_user(econia, user); // Init test market, user
        let addr = s_a_o(user); // Get user address
        r_m_bct_to(addr, 100); // Mint 100 base coins to user
        r_m_qct_to(addr, 200); // Mint 200 base coins to user
        a_i_s_n(addr); // Increment mock sequence number
        deposit<BCT, QCT, E0>(user, 75, 150); // Deposit collateral
        a_i_s_n(addr); // Increment mock sequence number
        withdraw<BCT, QCT, E0>(user, 5, 0); // Withdraw 5 base coins
        // Assert correct coin store balances
        assert!(c_b<BCT>(addr) == 30 && c_b<QCT>(addr) == 50, 0);
        // Borrow immutable reference to user's order collateral
        let o_c = borrow_global<OC<BCT, QCT, E0>>(addr);
        // Assert collateral holdings update correctly
        assert!(c_v<BCT>(&o_c.b_c) == 70 && c_v<QCT>(&o_c.q_c) == 150, 1);
        // Assert withdraw availability updates correctly
        assert!(o_c.b_a == 70 && o_c.q_a == 150, 2);
        // Manually update available quote coins
        borrow_global_mut<OC<BCT, QCT, E0>>(addr).q_a = 140;
        a_i_s_n(addr); // Increment mock sequence number
        withdraw<BCT, QCT, E0>(user, 0, 20); // Withdraw 20 quote coins
        // Assert correct coin store balances
        assert!(c_b<BCT>(addr) == 30 && c_b<QCT>(addr) == 70, 3);
        // Borrow immutable reference to user's order collateral
        let o_c = borrow_global<OC<BCT, QCT, E0>>(addr);
        // Assert collateral holdings update correctly
        assert!(c_v<BCT>(&o_c.b_c) == 70 && c_v<QCT>(&o_c.q_c) == 130, 4);
        // Assert withdraw availability updates correctly
        assert!(o_c.b_a == 70 && o_c.q_a == 120, 5);
        a_i_s_n(addr); // Increment mock sequence number
        withdraw<BCT, QCT, E0>(user, 70, 120); // Withdraw all possible
        // Assert correct coin store balances
        assert!(c_b<BCT>(addr) == 100 && c_b<QCT>(addr) == 190, 6);
        // Borrow immutable reference to user's order collateral
        let o_c = borrow_global<OC<BCT, QCT, E0>>(addr);
        // Assert collateral holdings update correctly
        assert!(c_v<BCT>(&o_c.b_c) == 0 && c_v<QCT>(&o_c.q_c) == 10, 7);
        // Assert withdraw availability updates correctly
        assert!(o_c.b_a == 0 && o_c.q_a == 0, 8);
    }

    // Tests <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
}