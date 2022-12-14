/// # Dynamic scaling
///
/// ## Coins
///
/// This implementation provides market data structures for trading
/// `Coin` types ("coins") against one another. Each coin has a
/// corresponding `CoinType` ("coin type"), and each instantiation of a
/// coin has an associated `u64` amount (`Coin<CoinType>.value`).
///
/// Coins can be traded against one another in a "trading pair", which
/// contains a "base coin" that is denominated in terms of a "quote
/// coin" (terminology inherited from Forex markets). At present the
/// most common cryptocurrency trading pair is `BTC/USD`, which
/// corresponds to Bitcoin (base coin) denominated in United States
/// Dollars (quote "coin"): $29,759.51 per Bitcoin at the time of this
/// writing.
///
/// Notably, for the above example, neither `BTC` nor `USD` actually
/// correspond to `Coin` types on the Aptos blockchain, but in all
/// likelihood these two assets will come to be represented on-chain as
/// a wrapped Bitcoin variant (coin type `wBTC` or similar) and a
/// USD-backed stablecoin, respectively, with the latter issued by a
/// centralized minting authority under the purview of the United States
/// government, for example `USDC`.
///
/// Despite the risk of arbitrary seizure by centralized stablecoin
/// issuers, centralized stablecoins like `USDC` have nevertheless
/// become the standard mode of denomination for on-chain trading, so
/// for illustrative purposes, USDC will be taken as the default quote
/// coin for future examples.
///
/// ## Decimal price
///
/// While `Coin` types have a `u64` value, the user-facing
/// representation of this amount often takes the form of a decimal, for
/// example, `100.75 USDC`, corresponding to 100 dollars and 75 cents.
/// More precision is still possible, though, with `USDC` commonly
/// offering up to 6 decimal places on other blockchains, so that a user
/// can hold an amount like `500.123456 USDC`. On Aptos, this would
/// correspond to a `Coin<USDC>.value` of `500123456` and a
/// `CoinInfo<USDC>.decimals` of `6`. Similarly, base coins may have an
/// arbitrary number of decimals, even though their underlying value is
/// still stored as a `u64`.
///
/// For a given trading pair, the conversion between quote coin and base
/// coin is achieved by simple multiplication and division:
/// * $coins_{quote} = coins_{base} * price$
/// * $coins_{base} = coins_{quote} / price$
///
/// For example, 2 `wBTC` at a price of `29,759.51 USDC` per `wBTC` per
/// corresponds to $2 * 29,759.51 =$ `59,519.02 USDC`, while `59,519.02
/// USDC` corresponds to $59,519.02 / 29,759.51 =$ `2 wBTC`
///
/// ## Scaled integer price
///
/// Again, however, coin values are ultimately represented as `u64`
/// amounts, and similarly, the present implementation's matching engine
/// relies on `u64` prices. Hence a price "scale factor" is sometimes
/// required, for instance when trading digital assets having a
/// relatively low valuation:
///
/// Consider recently-issued protocol coin `PRO`, which has 3 decimal
/// places, a circulating supply of 1 billion, and a `USDC`-denominated
/// market cap of $100,000. A single user-facing representation of a
/// coin, `1.000 PRO`, thus corresponds to `1000` indivisible subunits
/// and has a market price of $100,000 / 10^9 =$ `0.0001 USDC`, which
/// means that one indivisible subunit of `PRO` has a market value of
/// $0.0001 / 1000 =$ `0.0000001 USDC`. Except `USDC` only has 6 decimal
/// places, meaning that an indivisible subunit of `PRO` costs less than
/// one indivisible subunit of `USDC` (`0.000001 USDC`). Hence, an order
/// for `2.567 PRO` would be invalid, since it would correspond to
/// `0.0000002567 USDC`, an unrepresentable amount.
///
/// The proposed solution is a scaled integer price, defined as the
/// number of quote subunits per `SF` base subunits (`SF` denoting
/// scale factor):
/// * $price_{scaled} = \frac{subunits_{quote}}{subunits_{base} / SF} =$
///   $SF(\frac{subunits_{quote}}{subunits_{base}})$
/// * $subunits_{base} = SF (subunits_{quote} / price_{scaled})$
/// * $subunits_{quote} = price_{scaled} (subunits_{base} / SF$
///
/// For instance, a scale factor of 1,000 for the current
/// example yields prices denoting the number of `USDC` subunits
/// (`0.000001 USDC`) per 1,000 `PRO` subunits (`1.000 PRO`). At a
/// nominal price of `0.0001 USDC` per `1.000 PRO`, the scaled integer
/// price would thus be `100`, a valid `u64`.  Likewise, if the price
/// were to fall to `0.000001 USDC` per `1.000 PRO`, the scaled integer
/// price would then be `1`, still a valid `u64`. Here, the base coin
/// can only be transacted in amounts that are integer multiples of the
/// scale factor, because otherwise the corresponding number of quote
/// coin subunits could assume a non-integer value: a user may place an
/// order to trade `1.000 PRO` or `2.000 PRO`, but not `1.500 PRO`,
/// because at a scaled integer price of `1`, it would require 1.5
/// indivisible `USDC` subunits to settle the trade, an amount that
/// cannot be represented in a `u64`.
///
/// ## Market effects
///
/// If, eventually, the `USDC`-denominated market capitalization of
/// `PRO` were to increase to $100B, then each `1.000 PRO` would assume
/// a nominal value of `$100`, and a scale factor of `1000` would not
/// provide adequate trading granularity: a user could place an order
/// for `1.000 PRO` (`100 USDC`) or `2.000 PRO` (`200 USDC`), but
/// due to the integer-multiple lot size requirement described above,
/// enforced at the algorithm level, it would be impossible to place an
/// order for `.5 PRO` (`50 USDC`). This limitation would almost
/// certainly restrict retail trading activity, thus reducing price
/// discovery efficiency, and so the scale factor of `1000` would no
/// longer be appropriate.
///
/// But what is the most appropriate new scale factor for this mature
/// trading pair? `100`? `10`? `1`? What happens if the price later
/// plummets? And if the scale factor should be updated, then who
/// executes the code change, and when do they do it? Shall the
/// centralized authority who mints USDC (and who also has the power to
/// arbitrarily seize anyone's assets) additionally be granted the
/// authority to change the scale factor at any time? What if said
/// entity, of for that matter, any centralized entity that can either
/// act maliciously or be coerced, intentionally chooses an
/// inappropriate scale factor in the interest of halting activity on an
/// arbitrary trading pair?
///
/// With regard to choosing an appropriate scale factor, or more broadly
/// for facilitating trading pairs in general, the present
/// implementation's solution is to simply "let the market decide", via
/// a permissionless market registration system that allows anyone to
/// register any trading pair, with any scale factor of the form
/// $10^E, E\in \{0, 1, 2, \ldots, 19\}$, as long as the trading pair
/// has not already been initialized. Hence, when a new coin becomes
/// available, several trading pairs are likely to be established across
/// different scale factors, and the correspondingly fractured liquidity
/// will tend to gravitate towards a preferred scale factor. As prices
/// go up or down, liquidity will naturally migrate to the most
/// efficient scale factor, without any input from a centralized entity.
///
/// # Data structures
///
/// ## Market info
///
/// A trading pair, or market, is fully specified by a unique `MI`
/// (Market info) struct, which has fields for a base coin type, a quote
/// coin type, and a so-called "scale exponent" (`E` as above,
/// corresponding to a power of 10). These types are represented in
/// other functions and structs as `<B, Q, E>`.
///
/// Since markets are permissionless, anyone can register a market,
/// assuming that the correspondingly unique `MI` specifier has not
/// already been registered under the market registry, `MR`, stored at
/// the Econia address. The account that registers a market is known as
/// a "host", because during registration they agree to host under their
/// account an `Econia::Book::OB` that will facilitate trading.
///
/// ## Scale exponents and factors
///
/// The scale exponent types `E0`, `E1`, ..., `E19`, correspond to the
/// scale factors `F0`, `F1`, ... `F19`, with lookup
/// functionality provided by `scale_factor<E>()`. Notably, scale
/// exponents are types, while scale factors are `u64`, with the former
/// enabling lookup in global storage, and the latter enabling integer
/// arithmetic at the matching engine level. From a purely computer
/// science perspective, it would actually be more straightforward for
/// scale exponents and factors to correspond to powers of two, but
/// since the present implementation is financially-motivated, powers of
/// 10 are instead used. Hence the largest scale factor is `F19`
/// $= 10^{19} =$ `10000000000000000000`, the largest power of ten that
/// can be represented in a `u64`
///
/// ## Book module
///
/// The core order book data structure, `Econia::Book::OB`, is
/// implemented purely in Move, to facilitate coverage testing per the
/// `move` CLI, which would not be possible (at least as of the time of
/// this writing) if it were implemented in a module with Aptos native
/// functions. See `Econia::Caps` for further discussion.
///
/// ---
///
module Econia::Registry {

    // Uses >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    use aptos_framework::coin::{
        is_coin_initialized as c_i_c_i
    };

    use aptos_framework::iterable_table::{
        add as t_a,
        contains as t_c,
        new as t_n,
        IterableTable as T
    };

    use aptos_framework::type_info::{
        account_address as ti_a_a,
        module_name as ti_m_n,
        struct_name as ti_s_n,
        type_of as ti_t_o,
        TypeInfo as TI
    };

    use Econia::Book::{
        init_book as b_i_b
    };

    use Econia::Caps::{
        book_f_c,
    };

    use std::signer::{
        address_of
    };

    // Uses <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Friends >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    friend Econia::Init;
    friend Econia::User;

    // Friends <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Test-only uses >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[test_only]
    use aptos_framework::coin::{
        BurnCapability as CBC,
        deposit as c_d,
        initialize as c_i,
        MintCapability as CMC,
        mint as c_m
    };

    #[test_only]
    use aptos_framework::iterable_table::{
        borrow as t_b,
    };

    #[test_only]
    use Econia::Book::{
        scale_factor as book_scale_factor,
    };

    #[test_only]
    use Econia::Caps::{
        init_caps as c_i_c
    };

    #[test_only]
    use std::string::{
        utf8
    };

    // Test-only uses <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Structs >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    // Scale exponent types
    struct E0{}
    struct E1{}
    struct E2{}
    struct E3{}
    struct E4{}
    struct E5{}
    struct E6{}
    struct E7{}
    struct E8{}
    struct E9{}
    struct E10{}
    struct E11{}
    struct E12{}
    struct E13{}
    struct E14{}
    struct E15{}
    struct E16{}
    struct E17{}
    struct E18{}
    struct E19{}

    /// Market info
    struct MI has copy, drop, store {
        /// Base CoinType TypeInfo
        b: TI,
        /// Quote CoinType TypeInfo
        q: TI,
        /// Scale exponent TypeInfo
        e: TI
    }

    #[show_iter_table(t)]
    /// Market registry
    struct MR has key {
        /// Table from `MI` to address hosting the corresponding `MC`
        t: T<MI, address>
    }

    // Structs <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Error codes >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// When account/address is not Econia
    const E_NOT_ECONIA: u64 = 0;
    /// When wrong module
    const E_WRONG_MODULE: u64 = 1;
    /// When wrong type for exponent flag
    const E_WRONG_EXPONENT_T: u64 = 2;
    /// When market registry not initialized
    const E_NO_REGISTRY: u64 = 3;
    /// When a given market is already registered
    const E_REGISTERED: u64 = 4;
    /// When a type does not correspond to a coin
    const E_NOT_COIN: u64 = 5;
    /// When registry already exists
    const E_REGISTRY_EXISTS: u64 = 6;

    // Error codes <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // General constants >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    // Scale factors
    const F0 : u64 = 1;
    const F1 : u64 = 10;
    const F2 : u64 = 100;
    const F3 : u64 = 1000;
    const F4 : u64 = 10000;
    const F5 : u64 = 100000;
    const F6 : u64 = 1000000;
    const F7 : u64 = 10000000;
    const F8 : u64 = 100000000;
    const F9 : u64 = 1000000000;
    const F10: u64 = 10000000000;
    const F11: u64 = 100000000000;
    const F12: u64 = 1000000000000;
    const F13: u64 = 10000000000000;
    const F14: u64 = 100000000000000;
    const F15: u64 = 1000000000000000;
    const F16: u64 = 10000000000000000;
    const F17: u64 = 100000000000000000;
    const F18: u64 = 1000000000000000000;
    const F19: u64 = 10000000000000000000;

    /// This module's name
    const M_NAME: vector<u8> = b"Registry";

    // General constants <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Test-only structs >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[test_only]
    /// Base coin type
    struct BCT{}

    #[test_only]
    /// Base coin capabilities
    struct BCC has key {
        /// Mint capability
        m: CMC<BCT>,
        /// Burn capability
        b: CBC<BCT>
    }

    #[test_only]
    /// Quote coin type
    struct QCT{}

    #[test_only]
    /// Quote coin capabilities
    struct QCC has key {
        /// Mint capability
        m: CMC<QCT>,
        /// Burn capability
        b: CBC<QCT>
    }

    #[test_only]
    struct E20{} // Invalid scale exponent type

    // Test-only structs <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Test-only constants >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[test_only]
    /// Base coin type coin name
    const BCT_CN: vector<u8> = b"Base";
    #[test_only]
    /// Base coin type coin symbol
    const BCT_CS: vector<u8> = b"B";
    #[test_only]
    /// Base coin type decimal
    const BCT_D: u64 = 4;
    #[test_only]
    /// Base coin type type name
    const BCT_TN: vector<u8> = b"BCT";
    #[test_only]
    /// Quote coin type coin name
    const QCT_CN: vector<u8> = b"Quote";
    #[test_only]
    /// Quote coin type coin symbol
    const QCT_CS: vector<u8> = b"Q";
    #[test_only]
    /// Base coin type decimal
    const QCT_D: u64 = 8;
    #[test_only]
    /// Quote coin type type name
    const QCT_TN: vector<u8> = b"QCT";

    // Test-only constants <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Public friend functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Publish `MR` to Econia account, aborting for all other accounts
    /// or if `MR` already exists
    public(friend) fun init_registry(
        account: &signer
    ) {
        let addr = address_of(account); // Get signer address
        assert!(addr == @Econia, E_NOT_ECONIA); // Assert Econia signer
        // Assert registry does not already exist
        assert!(!exists<MR>(addr), E_REGISTRY_EXISTS);
        // Move empty market registry to account
        move_to<MR>(account, MR{t: t_n<MI, address>()});
    }

    /// Return `true` if given market is registered
    public(friend) fun is_registered<B, Q, E>(
    ): bool
    acquires MR {
        // Return false if no market registry at Econia account
        if (!exists<MR>(@Econia)) return false;
         // Get market info for given type arguments
        let m_i = MI{b: ti_t_o<B>(), q: ti_t_o<Q>(), e: ti_t_o<E>()};
        // Return if registry table contains market information
        t_c(&borrow_global<MR>(@Econia).t, m_i)
    }

    /// Return scale factor corresponding to scale exponent type `E`
    public(friend) fun scale_factor<E>():
    u64 {
        let t_i = ti_t_o<E>(); // Get type info of exponent type flag
        // Verify exponent type flag is from Econia address
        verify_address(ti_a_a(&t_i), @Econia, E_NOT_ECONIA);
        // Verify exponent type flag is from this module
        verify_bytestring(ti_m_n(&t_i), M_NAME, E_WRONG_MODULE);
        let s_n = ti_s_n(&t_i); // Get type struct name
        // Return corresponding scale factor
        if (s_n == ti_s_n(&ti_t_o<E0>() )) return F0;
        if (s_n == ti_s_n(&ti_t_o<E1>() )) return F1;
        if (s_n == ti_s_n(&ti_t_o<E2>() )) return F2;
        if (s_n == ti_s_n(&ti_t_o<E3>() )) return F3;
        if (s_n == ti_s_n(&ti_t_o<E4>() )) return F4;
        if (s_n == ti_s_n(&ti_t_o<E5>() )) return F5;
        if (s_n == ti_s_n(&ti_t_o<E6>() )) return F6;
        if (s_n == ti_s_n(&ti_t_o<E7>() )) return F7;
        if (s_n == ti_s_n(&ti_t_o<E8>() )) return F8;
        if (s_n == ti_s_n(&ti_t_o<E9>() )) return F9;
        if (s_n == ti_s_n(&ti_t_o<E10>())) return F10;
        if (s_n == ti_s_n(&ti_t_o<E11>())) return F11;
        if (s_n == ti_s_n(&ti_t_o<E12>())) return F12;
        if (s_n == ti_s_n(&ti_t_o<E13>())) return F13;
        if (s_n == ti_s_n(&ti_t_o<E14>())) return F14;
        if (s_n == ti_s_n(&ti_t_o<E15>())) return F15;
        if (s_n == ti_s_n(&ti_t_o<E16>())) return F16;
        if (s_n == ti_s_n(&ti_t_o<E17>())) return F17;
        if (s_n == ti_s_n(&ti_t_o<E18>())) return F18;
        if (s_n == ti_s_n(&ti_t_o<E19>())) return F19;
        abort E_WRONG_EXPONENT_T // Else abort
    }

    // Public friend functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Public entry functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[cmd(desc=b"Create a new market B-Q-E")]
    /// Register a market for the given base coin type `B`, quote coin
    /// type `Q`, and scale exponent `E` , aborting if registry not
    /// initialized or if market already registered
    public entry fun register_market<B, Q, E>(
        host: &signer
    ) acquires MR {
        verify_market_types<B, Q, E>(); // Verify valid type arguments
        // Assert market registry is initialized at Econia account
        assert!(exists<MR>(@Econia), E_NO_REGISTRY);
        // Get market info for given type arguments
        let m_i = MI{b: ti_t_o<B>(), q: ti_t_o<Q>(), e: ti_t_o<E>()};
        // Borrow mutable reference to market registry table
        let r_t = &mut borrow_global_mut<MR>(@Econia).t;
        // Assert requested market not already registered
        assert!(!t_c(r_t, m_i), E_REGISTERED);
        // Initialize empty order book under host account
        b_i_b<B, Q, E>(host, scale_factor<E>(), &book_f_c());
        // Register market-host relationship
        t_a(r_t, m_i, address_of(host));
    }

    // Public entry functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Private functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Assert `a1` equals `a2`, aborting with code `e` if not
    fun verify_address(
        a1: address,
        a2: address,
        e: u64
    ) {
        assert!(a1 == a2, e); // Assert equality
    }

    /// Assert `s1` equals `s2`, aborting with code `e` if not
    fun verify_bytestring(
        bs1: vector<u8>,
        bs2: vector<u8>,
        e: u64
    ) {
        assert!(bs1 == bs2, e); // Assert equality
    }

    /// Assert `B` and `Q` are coins, and that `E` is scale exponent
    fun verify_market_types<B, Q, E>() {
        assert!(c_i_c_i<B>(), E_NOT_COIN); // Assert base quote type
        assert!(c_i_c_i<Q>(), E_NOT_COIN); // Assert quote coin type
        // Assert scale exponent type has corresponding scale factor
        scale_factor<E>();
    }

    /// Assert `t1` equals `t2`, aborting with code `e` if not
    fun verify_t_i(
        t1: &TI,
        t2: &TI,
        e: u64
    ) {
        verify_address(ti_a_a(t1), ti_a_a(t2), e); // Verify address
        verify_bytestring(ti_m_n(t1), ti_m_n(t2), e); // Verify module
        verify_bytestring(ti_s_n(t1), ti_s_n(t2), e); // Verify struct
    }

    // Private functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Test-only functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    #[test_only]
    /// Initialize base and quote coin types under Econia account
    fun init_coin_types(
        econia: &signer
    ) {
        // Assert initializing coin types under Econia account
        assert!(address_of(econia) == @Econia, 0);
        // Initialize base coin type, storing mint/burn capabilities
        let(m, b) = c_i<BCT>(econia, utf8(BCT_CN), utf8(BCT_CS), BCT_D, false);
        // Save capabilities in global storage
        move_to(econia, BCC{m, b});
        // Initialize quote coin type, storing mint/burn capabilities
        let(m, b) = c_i<QCT>(econia, utf8(QCT_CN), utf8(QCT_CS), QCT_D, false);
        // Save capabilities in global storage
        move_to(econia, QCC{m, b});
    }

    #[test_only]
    /// Mint `amount` of `BCT` to `aptos_framework::Coin::Coinstore` for
    /// `user`
    public fun mint_bct_to(
        user: address,
        amount: u64
    ) acquires BCC {
        // Mint and deposit to user
        c_d<BCT>(user, c_m<BCT>(amount, &borrow_global<BCC>(@Econia).m));
    }

    #[test_only]
    /// Mint `amount` of `QCT` to `aptos_framework::Coin::Coinstore` for
    /// `user`
    public fun mint_qct_to(
        user: address,
        amount: u64
    ) acquires QCC {
        // Mint and deposit to user
        c_d<QCT>(user, c_m<QCT>(amount, &borrow_global<QCC>(@Econia).m));
    }

    #[test_only]
    /// Register base and quote coin types, with corresponding market,
    /// assuming registry has already been initialized
    public entry fun register_test_market(
        econia: &signer
    ) acquires MR {
        init_coin_types(econia); // Initialize test coin types
        register_market<BCT, QCT, E0>(econia); // Register market
    }

    #[test_only]
    /// Register base and quote coin types, with corresponding market
    /// having scale expenonet `E`, assuming registry has already been
    /// initialized
    public entry fun register_scaled_test_market<E>(
        econia: &signer
    ) acquires MR {
        init_coin_types(econia); // Initialize test coin types
        register_market<BCT, QCT, E>(econia); // Register market
    }

    // Test-only functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

    // Tests >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[test(econia = @Econia)]
    #[expected_failure(abort_code = 6)]
    /// Verify registry publication fails for re-registration
    public entry fun init_registry_failure_exists(
        econia: &signer
    ) {
        init_registry(econia); // Initialize
        init_registry(econia); // Attempt invalid re-initialization
    }

    #[test(account = @TestUser)]
    #[expected_failure(abort_code = 0)]
    /// Verify registry publication fails for non-Econia account
    public entry fun init_registry_failure_not_econia(
        account: &signer
    ) {
        init_registry(account); // Attempt invalid initialization
    }

    #[test(econia = @Econia)]
    /// Verify registry publish correctly
    public entry fun init_registry_success(
        econia: &signer
    ) {
        init_registry(econia); // Initialize registry
        // Assert exists at Econia account
        assert!(exists<MR>(address_of(econia)), 0);
    }

    #[test]
    /// Verify false return for market registry not initialized
    fun is_registered_false_no_mr()
    acquires MR {
        // Assert false return
        assert!(!is_registered<BCT, QCT, E0>(), 0);
    }

    #[test(econia = @Econia)]
    /// Verify false return for no such market registered
    public entry fun is_registered_false_not_registered(
        econia: &signer
    ) acquires MR {
        init_registry(econia); // Initialize registry
        // Assert false return for unregistered market
        assert!(!is_registered<BCT, QCT, E0>(), 0);
    }

    #[test(econia = @Econia)]
    /// Verify true return for registered market
    public entry fun is_registered_true(
        econia: &signer
    ) acquires MR {
        c_i_c(econia); // Initialize friend-like capabilities
        init_registry(econia); // Initialize registry
        register_test_market(econia); // Register test market
        // Assert true return for registered test market
        assert!(is_registered<BCT, QCT, E0>(), 0);
    }

    #[test]
    /// Pack market info and verify fields
    fun pack_market_info() {
        // Pack market info for test coin types
        let m_i = MI{b: ti_t_o<BCT>(), q: ti_t_o<QCT>(), e: ti_t_o<E2>()};
        verify_t_i(&m_i.b, &ti_t_o<BCT>(), 0); // Verify base coin type
        verify_t_i(&m_i.q, &ti_t_o<QCT>(), 1); // Verify quote coin type
        // Verify scale exponent type
        verify_t_i(&m_i.e, &ti_t_o<E2>(), 2);
    }

    #[test(
        econia = @Econia,
        host = @TestUser
    )]
    #[expected_failure(abort_code = 3)]
    /// Verify failure for uninitialized market registry
    public entry fun register_market_failure_no_registry(
        econia: &signer,
        host: &signer
    ) acquires MR {
        init_coin_types(econia); // Initialize coin types
        // Attempt invalid registration
        register_market<BCT, QCT, E0>(host);
    }

    #[test(
        econia = @Econia,
        host = @TestUser
    )]
    #[expected_failure(abort_code = 4)]
    /// Verify failure for attempted re-registration
    public entry fun register_market_failure_registered(
        econia: &signer,
        host: &signer
    ) acquires MR {
        init_coin_types(econia); // Initialize coin types
        c_i_c(econia); // Initialize friend-like capabilities
        init_registry(econia); // Initialize registry
        register_market<BCT, QCT, E0>(host); // Register market
        // Attempt invalid registration
        register_market<BCT, QCT, E0>(host);
    }

    #[test(
        econia = @Econia,
        host = @TestUser
    )]
    /// Verify successful registration
    public entry fun register_market_success(
        econia: &signer,
        host: &signer
    ) acquires MR {
        init_coin_types(econia); // Initialize coin types
        init_registry(econia); // Initialize registry
        c_i_c(econia); // Initialize friend-like capabilities
        register_market<BCT, QCT, E4>(host); // Register market
        // Assert order book has correct scale factor
        assert!(book_scale_factor<BCT, QCT, E4>(
            address_of(host), &book_f_c()) == scale_factor<E4>(), 0);
        // Borrow immutable reference to market registry
        let r_t = &borrow_global<MR>(@Econia).t;
        // Define market info struct to look up in table
        let m_i = MI{b: ti_t_o<BCT>(), q: ti_t_o<QCT>(), e: ti_t_o<E4>()};
        // Assert registry reflects market-host relationship
        assert!(*t_b(r_t, m_i) == address_of(host), 2);
    }

    #[test]
    #[expected_failure(abort_code = 2)]
    /// Verify failure for invalid type
    fun scale_factor_failure() {scale_factor<E20>();}

    #[test]
    /// Verify successful return for all scale exponent types
    fun scale_factor_success() {
        assert!(scale_factor<E0>()  == F0 , 0 );
        assert!(scale_factor<E1>()  == F1 , 1 );
        assert!(scale_factor<E2>()  == F2 , 2 );
        assert!(scale_factor<E3>()  == F3 , 3 );
        assert!(scale_factor<E4>()  == F4 , 4 );
        assert!(scale_factor<E5>()  == F5 , 5 );
        assert!(scale_factor<E6>()  == F6 , 6 );
        assert!(scale_factor<E7>()  == F7 , 7 );
        assert!(scale_factor<E8>()  == F8 , 8 );
        assert!(scale_factor<E9>()  == F9 , 9 );
        assert!(scale_factor<E10>() == F10, 10);
        assert!(scale_factor<E11>() == F11, 11);
        assert!(scale_factor<E12>() == F12, 12);
        assert!(scale_factor<E13>() == F13, 13);
        assert!(scale_factor<E14>() == F14, 14);
        assert!(scale_factor<E15>() == F15, 15);
        assert!(scale_factor<E16>() == F16, 16);
        assert!(scale_factor<E17>() == F17, 17);
        assert!(scale_factor<E18>() == F18, 18);
        assert!(scale_factor<E19>() == F19, 19);
    }

    #[test]
    #[expected_failure(abort_code = 0)]
    /// Verify abort for different address
    fun verify_address_failure() {
        verify_address(@TestUser, @Econia, E_NOT_ECONIA);
    }

    #[test]
    /// Verify no error raised for same address
    fun verify_address_success() {
        verify_address(@Econia, @Econia, 0);
    }

    #[test]
    #[expected_failure(abort_code = 1)]
    /// Verify abort for different bytestrings
    fun verify_bytestring_failure() {
        verify_bytestring(M_NAME, b"foo", E_WRONG_MODULE);
    }

    #[test]
    /// Verify no error raised for same bytestring
    fun verify_bytestring_success() {
        verify_bytestring(M_NAME, M_NAME, 0);
    }

    #[test(econia = @Econia)]
    #[expected_failure(abort_code = 5)]
    /// Verify failure for invalid base coin type
    fun verify_market_types_failure_b(
        econia: &signer
    ) {
        init_coin_types(econia); // Initialize coins
        // Pass invalid base coin type
        verify_market_types<E0, QCT, E0>();
    }

    #[test(econia = @Econia)]
    #[expected_failure(abort_code = 5)]
    /// Verify failure for invalid quote coin type
    fun verify_market_types_failure_q(
        econia: &signer
    ) {
        init_coin_types(econia); // Initialize coins
        // Pass invalid quote coin type
        verify_market_types<BCT, E0, E0>();
    }

    #[test(econia = @Econia)]
    /// Verify success for all valid types
    fun verify_market_types_success(
        econia: &signer
    ) {
        init_coin_types(econia); // Initialize coins
        verify_market_types<BCT, QCT, E0>(); // Verify sample market
    }

    // Tests <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
}