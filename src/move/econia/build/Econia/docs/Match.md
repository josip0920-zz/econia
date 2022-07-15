
<a name="0xc0deb00c_Match"></a>

# Module `0xc0deb00c::Match`

Matching engine functionality, integrating user-side and book-side
modules


-  [Constants](#@Constants_0)
-  [Function `fill_market_order`](#0xc0deb00c_Match_fill_market_order)
    -  [Parameters](#@Parameters_1)
    -  [Returns](#@Returns_2)
    -  [Assumptions](#@Assumptions_3)


<pre><code><b>use</b> <a href="Book.md#0xc0deb00c_Book">0xc0deb00c::Book</a>;
<b>use</b> <a href="User.md#0xc0deb00c_User">0xc0deb00c::User</a>;
</code></pre>



<a name="@Constants_0"></a>

## Constants


<a name="0xc0deb00c_Match_ASK"></a>

Ask flag


<pre><code><b>const</b> <a href="Match.md#0xc0deb00c_Match_ASK">ASK</a>: bool = <b>true</b>;
</code></pre>



<a name="0xc0deb00c_Match_BID"></a>

Bid flag


<pre><code><b>const</b> <a href="Match.md#0xc0deb00c_Match_BID">BID</a>: bool = <b>false</b>;
</code></pre>



<a name="0xc0deb00c_Match_fill_market_order"></a>

## Function `fill_market_order`

Fill a market order against the book as much as possible,
returning when there is no liquidity left or when order is
completely filled


<a name="@Parameters_1"></a>

### Parameters

* <code>host</code> Host of corresponding order book
* <code>addr</code>: Address of user placing market order
* <code>side</code>: <code><a href="Match.md#0xc0deb00c_Match_ASK">ASK</a></code> or <code><a href="Match.md#0xc0deb00c_Match_BID">BID</a></code>, denoting the side on the order book
which should be filled against. If <code><a href="Match.md#0xc0deb00c_Match_ASK">ASK</a></code>, user is submitting
a market buy, if <code><a href="Match.md#0xc0deb00c_Match_BID">BID</a></code>, user is submitting a market sell
* <code>size</code>: Base coin parcels to be filled
* <code>book_cap</code>: Immutable reference to <code>Econia::Book:FriendCap</code>


<a name="@Returns_2"></a>

### Returns

* <code>u64</code>: Amount of base coin parcels left unfilled


<a name="@Assumptions_3"></a>

### Assumptions

* Order book has been properly initialized at host address


<pre><code><b>public</b> <b>fun</b> <a href="Match.md#0xc0deb00c_Match_fill_market_order">fill_market_order</a>&lt;B, Q, E&gt;(host: <b>address</b>, addr: <b>address</b>, side: bool, size: u64, book_cap: &<a href="Book.md#0xc0deb00c_Book_FriendCap">Book::FriendCap</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="Match.md#0xc0deb00c_Match_fill_market_order">fill_market_order</a>&lt;B, Q, E&gt;(
    host: <b>address</b>,
    addr: <b>address</b>,
    side: bool,
    size: u64,
    book_cap: &BookCap
): u64 {
    // Get number of positions on corresponding order book side
    <b>let</b> n_positions = <b>if</b> (side == <a href="Match.md#0xc0deb00c_Match_ASK">ASK</a>) n_asks&lt;B, Q, E&gt;(host, book_cap)
        <b>else</b> n_bids&lt;B, Q, E&gt;(host, book_cap);
    // Get scale factor of corresponding order book
    <b>let</b> scale_factor = scale_factor&lt;B, Q, E&gt;(host, book_cap);
    // Return full order size <b>if</b> no positions on book
    <b>if</b> (n_positions == 0) <b>return</b> size;
    // Initialize traversal, storing <a href="ID.md#0xc0deb00c_ID">ID</a> of target position, <b>address</b>
    // of user holding it, the parent field of corresponding tree
    // node, child index of corresponding node, and amount filled
    <b>let</b> (target_id, target_addr, target_p_f, target_c_i, filled) =
        init_traverse_fill&lt;B, Q, E&gt;(
            host, addr, side, size, n_positions, book_cap);
    <b>loop</b> { // Begin traversal <b>loop</b>
        // Determine <b>if</b> last match was an exact fill against book
        <b>let</b> exact_match = (filled == size);
        // Route funds between conterparties, <b>update</b> open orders
        process_fill&lt;B, Q, E&gt;(target_addr, addr, side, target_id, filled,
                              scale_factor, exact_match);
        size = size - filled; // Decrement size left <b>to</b> match
        // If incoming order unfilled and can traverse
        <b>if</b> (size &gt; 0 && n_positions &gt; 1) {
            // Traverse pop fill <b>to</b> next position
            (target_id, target_addr, target_p_f, target_c_i, filled) =
                traverse_pop_fill&lt;B, Q, E&gt;(
                    host, addr, side, size, n_positions, target_id,
                    target_p_f, target_c_i, book_cap);
            // Decrement count of positions on book for given side
            n_positions = n_positions - 1;
        } <b>else</b> { // If should not continute iterated traverse fill
            // If only a partial target fill, incoming fill complete
            <b>if</b> (size == 0 && !exact_match) {
                // Update either <b>min</b>/max order <a href="ID.md#0xc0deb00c_ID">ID</a> <b>to</b> target <a href="ID.md#0xc0deb00c_ID">ID</a>
                // reset_extreme_order_id(book, side, target_id)
            } <b>else</b> { // If need <b>to</b> pop but not iterate fill
                <b>if</b> (n_positions &gt; 1) { // If can traverse
                    // traverse_pop_set_extreme_id&lt;B, Q, E&gt;(host, side,
                    //    target_id, target_p_f, target_c_i, book_cap);
                } <b>else</b> { // If need <b>to</b> pop only position on book
                    // Pop position off the book
                    // pop&lt;B, Q, E&gt;(host, target_id);
                    // Set default extrema value for given size
                    // set default_extrema(side)
                };
            };
            <b>break</b> // Break out of <b>loop</b>
        };
    };
    size
}
</code></pre>



</details>