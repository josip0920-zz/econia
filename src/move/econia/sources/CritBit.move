/// A crit-bit tree is a compact binary prefix tree, similar to a binary
/// search tree, that stores a prefix-free set of bitstrings, like
/// n-bit integers or variable-length 0-terminated byte strings. For a
/// given set of keys there exists a unique crit-bit tree representing
/// the set, hence crit-bit trees do not requre complex rebalancing
/// algorithms like those of AVL or red-black binary search trees.
/// Crit-bit trees support the following operations, quickly:
///
/// * Membership testing
/// * Insertion
/// * Deletion
/// * Predecessor
/// * Successor
/// * Iteration
///
/// References:
///
/// * [Bernstein 2006](https://cr.yp.to/critbit.html)
/// * [Langley 2008](
///   https://www.imperialviolet.org/2008/09/29/critbit-trees.html)
/// * [Langley 2012](https://github.com/agl/critbit)
/// * [Tcler's Wiki 2021](https://wiki.tcl-lang.org/page/critbit)
///
/// The present implementation involves a tree with two types of nodes,
/// inner and outer. Inner nodes have two children each, while outer
/// nodes have no children. There are no nodes that have exactly one
/// child. Outer nodes store a key-value pair with a 128-bit integer as
/// a key, and an arbitrary value of generic type. Inner nodes do not
/// store a key, but rather, an 8-bit integer indicating the most
/// significant critical bit (crit-bit) of divergence between keys
/// located within the node's two subtrees: keys in the node's left
/// subtree have a 0 at the critical bit, while keys in the node's right
/// subtree have a 1 at the critical bit. Bit numbers are 0-indexed
/// starting at the least-significant bit (LSB), such that a critical
/// bit of 3, for instance, corresponds to a comparison between the
/// bitstrings `00...00000` and `00...01111`. Inner nodes are arranged
/// hierarchically, with the most sigificant critical bits at the top of
/// the tree. For instance, the keys `001`, `101`, `110`, and `111`
/// would be stored in a crit-bit tree as follows (right carets included
/// at left of illustration per issue with documentation build engine,
/// namely, the automatic stripping of leading whitespace in fenced code
/// blocks):
/// ```
/// >       2nd
/// >      /   \
/// >    001   1st
/// >         /   \
/// >       101   0th
/// >            /   \
/// >          110   111
/// ```
/// Here, the inner node marked `2nd` stores the integer 2, the inner
/// node marked `1st` stores the integer 1, and the inner node marked
/// `0th` stores the integer 0. Hence, the sole key in the left subtree
/// of the inner node marked `2nd` has 0 at bit 2, while all the keys in
/// the node's right subtree have 1 at bit 2. And similarly for the
/// inner node marked `0th`, its left child node does not have bit 0
/// set, while its right child does have bit 0 set.
///
/// ---
///
module Econia::CritBit {

    use Std::Vector::{
        borrow as v_b,
        borrow_mut as v_b_m,
        destroy_empty as v_d_e,
        empty as v_e,
        is_empty as v_i_e,
        length as v_l,
        pop_back as v_po_b,
        push_back as v_pu_b,
        swap_remove as v_s_r
    };

    #[test_only]
    use Std::Vector::{
        append as v_a,
    };

// Constants >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// `u128` bitmask with all bits set
    const HI_128: u128 = 0xffffffffffffffffffffffffffffffff;
    /// `u64` bitmask with all bits set
    const HI_64: u64 = 0xffffffffffffffff;
    /// `u64` bitmask with all bits set, to flag that a node is at root
    const ROOT: u64 = 0xffffffffffffffff;
    /// Most significant bit number for a `u128`
    const MSB_u128: u8 = 127;
    /// Bit number of node type flag in a `u64` vector index
    const N_TYPE: u8 = 63;
    /// Node type bit flag indicating inner node
    const IN: u64 = 0;
    /// Node type bit flag indicating outer node
    const OUT: u64 = 1;
    /// Left direction
    const L: bool = true;
    /// Right direction
    const R: bool = false;

// Constants <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

// Error codes >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// When a char in a bytestring is neither 0 nor 1
    const E_BIT_NOT_0_OR_1: u64 = 0;
    /// When attempting to destroy a non-empty crit-bit tree
    const E_DESTROY_NOT_EMPTY: u64 = 1;
    /// When an insertion key is already present in a crit-bit tree
    const E_HAS_K: u64 = 2;
    /// When unable to borrow from empty tree
    const E_BORROW_EMPTY: u64 = 3;
    /// When no matching key in tree
    const E_NOT_HAS_K: u64 = 4;
    /// When no more keys can be inserted
    const E_INSERT_FULL: u64 = 5;

// Error codes <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

// Structs >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Inner node
    struct I has store {
        // Documentation comments, specifically on struct fields,
        // apparently do not support fenced code blocks unless they are
        // preceded by a blank line...
        /// Critical bit position. Bit numbers 0-indexed from LSB:
        ///
        /// ```
        /// 11101...1010010101
        ///  bit 5 = 0 -|    |- bit 0 = 1
        /// ```
        c: u8,
        /// Parent node vector index. `ROOT` when node is root,
        /// otherwise corresponds to vector index of an inner node.
        p: u64,
        /// Left child node index. When bit 63 is set, left child is an
        /// outer node. Otherwise left child is an inner node.
        l: u64,
        /// Right child node index. When bit 63 is set, right child is
        /// an outer node. Otherwise right child is an inner node.
        r: u64
    }

    /// Outer node with key `k` and value `v`
    struct O<V> has store {
        /// Key, which would preferably be a generic type representing
        /// the union of {`u8`, `u64`, `u128`}. However this kind of
        /// union typing is not supported by Move, so the most general
        /// (and memory intensive) `u128` is instead specified strictly.
        /// Must be an integer for bitwise operations.
        k: u128,
        /// Value from node's key-value pair
        v: V,
        /// Parent node vector index. `ROOT` when node is root,
        /// otherwise corresponds to vector index of an inner node.
        p: u64,
    }

    /// A crit-bit tree for key-value pairs with value type `V`
    struct CB<V> has store {
        /// Root node index. When bit 63 is set, root node is an outer
        /// node. Otherwise root is an inner node. 0 when tree is empty
        r: u64,
        /// Inner nodes
        i: vector<I>,
        /// Outer nodes
        o: vector<O<V>>
    }

// Structs <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

// Binary operation helper functions >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Return the number of the most significant bit (0-indexed from
    /// LSB) at which two non-identical bitstrings, `s1` and `s2`, vary.
    /// To begin with, a bitwise XOR is used to flag all differing bits:
    /// ```
    /// >           s1: 11110001
    /// >           s2: 11011100
    /// >  x = s1 ^ s2: 00101101
    /// >                 |- critical bit = 5
    /// ```
    /// Here, the critical bit is equivalent to the bit number of the
    /// most significant set bit in XOR result `x = s1 ^ s2`. At this
    /// point, [Langley 2012](https://github.com/agl/critbit) notes that
    /// `x` bitwise AND `x - 1` will be nonzero so long as `x` contains
    /// at least some bits set which are of lesser significance than the
    /// critical bit:
    /// ```
    /// >               x: 00101101
    /// >           x - 1: 00101100
    /// > x = x & (x - 1): 00101100
    /// ```
    /// Thus he suggests repeating `x & (x - 1)` while the new result
    /// `x = x & (x - 1)` is not equal to zero, because such a loop will
    /// eventually reduce `x` to a power of two (excepting the trivial
    /// case where `x` starts as all 0 except bit 0 set, for which the
    /// loop never enters past the initial conditional check). Per this
    /// method, using the new `x` value for the current example, the
    /// second iteration proceeds as follows:
    /// ```
    /// >               x: 00101100
    /// >           x - 1: 00101011
    /// > x = x & (x - 1): 00101000
    /// ```
    /// The third iteration:
    /// ```
    /// >               x: 00101000
    /// >           x - 1: 00100111
    /// > x = x & (x - 1): 00100000
    /// ```
    /// Now, `x & x - 1` will equal zero and the loop will not begin a
    /// fourth iteration:
    /// ```
    /// >             x: 00100000
    /// >         x - 1: 00011111
    /// > x AND (x - 1): 00000000
    /// ```
    /// Thus after three iterations a corresponding critical bit bitmask
    /// has been determined. However, in the case where the two input
    /// strings vary at all bits of lesser significance than that of the
    /// critical bit, there may be required as many as `k - 1`
    /// iterations, where `k` is the number of bits in each string under
    /// comparison. For instance, consider the case of the two 8-bit
    /// strings `s1` and `s2` as follows:
    /// ```
    /// >              s1: 10101010
    /// >              s2: 01010101
    /// >     x = s1 ^ s2: 11111111
    /// >                  |- critical bit = 7
    /// > x = x & (x - 1): 11111110 [iteration 1]
    /// > x = x & (x - 1): 11111100 [iteration 2]
    /// > x = x & (x - 1): 11111000 [iteration 3]
    /// > ...
    /// ```
    /// Notably, this method is only suggested after already having
    /// indentified the varying byte between the two strings, thus
    /// limiting `x & (x - 1)` operations to at most 7 iterations. But
    /// for the present implementation, strings are not partioned into
    /// a multi-byte array, rather, they are stored as `u128` integers,
    /// so a binary search is instead proposed. Here, the same
    /// `x = s1 ^ s2` operation is first used to identify all differing
    /// bits, before iterating on an upper and lower bound for the
    /// critical bit number:
    /// ```
    /// >          s1: 10101010
    /// >          s2: 01010101
    /// > x = s1 ^ s2: 11111111
    /// >       u = 7 -|      |- l = 0
    /// ```
    /// The upper bound `u` is initialized to the length of the string
    /// (7 in this example, but 127 for a `u128`), and the lower bound
    /// `l` is initialized to 0. Next the midpoint `m` is calculated as
    /// the average of `u` and `l`, in this case `m = (7 + 0) / 2 = 3`,
    /// per truncating integer division. Now, the shifted compare value
    /// `s = r >> m` is calculated and updates are applied according to
    /// three potential outcomes:
    ///
    /// * `s == 1` means that the critical bit `c` is equal to `m`
    /// * `s == 0` means that `c < m`, so `u` is set to `m - 1`
    /// * `s > 1` means that `c > m`, so `l` us set to `m + 1`
    ///
    /// Hence, continuing the current example:
    /// ```
    /// >          x: 11111111
    /// > s = x >> m: 00011111
    /// ```
    /// `s > 1`, so `l = m + 1 = 4`, and the search window has shrunk:
    /// ```
    /// > x = s1 ^ s2: 11111111
    /// >       u = 7 -|  |- l = 4
    /// ```
    /// Updating the midpoint yields `m = (7 + 4) / 2 = 5`:
    /// ```
    /// >          x: 11111111
    /// > s = x >> m: 00000111
    /// ```
    /// Again `s > 1`, so update `l = m + 1 = 6`, and the window
    /// shrinks again:
    /// ```
    /// > x = s1 ^ s2: 11111111
    /// >       u = 7 -||- l = 6
    /// > s = x >> m: 00000011
    /// ```
    /// Again `s > 1`, so update `l = m + 1 = 7`, the final iteration:
    /// ```
    /// > x = s1 ^ s2: 11111111
    /// >       u = 7 -|- l = 7
    /// > s = x >> m: 00000001
    /// ```
    /// Here, `s == 1`, which means that `c = m = 7`. Notably this
    /// search has converged after only 3 iterations, as opposed to 7
    /// for the linear search proposed above, and in general such a
    /// search converges after log_2(`k`) iterations at most, where `k`
    /// is the number of bits in each of the strings `s1` and `s2` under
    /// comparison. Hence this search method improves the O(`k`) search
    /// proposed by [Langley 2012](https://github.com/agl/critbit) to
    /// O(log(`k`)), and moreover, determines the actual number of the
    /// critical bit, rather than just a bitmask with bit `c` set, as he
    /// proposes, which can also be easily generated via `1 << c`.
    fun crit_bit(
        s1: u128,
        s2: u128,
    ): u8 {
        let x = s1 ^ s2; // XOR result marked 1 at bits that differ
        let l = 0; // Lower bound on critical bit search
        let u = MSB_u128; // Upper bound on critical bit search
        loop { // Begin binary search
            let m = (l + u) / 2; // Calculate midpoint of search window
            let s = x >> m; // Calculate midpoint shift of XOR result
            if (s == 1) return m; // If shift equals 1, c = m
            if (s > 1) l = m + 1 else u = m - 1; // Update search bounds
        }
    }

    #[test]
    /// Verify successful determination of critical bit
    fun crit_bit_success() {
        let b = 0; // Start loop for bit 0
        while (b <= MSB_u128) { // Loop over all bit numbers
            // Compare 0 versus a bitmask that is only set at bit b
            assert!(crit_bit(0, 1 << b) == b, (b as u64));
            b = b + 1; // Increment bit counter
        };
    }

    /// Return `true` if `k` is set at bit `b`
    fun is_set(k: u128, b: u8): bool {k >> b & 1 == 1}

    /// Return `true` if vector index `i` indicates an outer node
    fun is_out(i: u64): bool {(i >> N_TYPE & OUT == OUT)}

    /// Convert flagged child node index `c` to unflagged outer node
    /// vector index, by AND with a bitmask that has only flag bit unset
    fun o_v(c: u64): u64 {c & HI_64 ^ OUT << N_TYPE}

    /// Convert unflagged outer node vector index `v` to flagged child
    /// node index, by OR with a bitmask that has only flag bit set
    fun o_c(v: u64): u64 {v | OUT << N_TYPE}

    #[test]
    /// Verify correct returns
    fun is_set_success() {
        assert!(is_set(u(b"11"), 0) && is_set(u(b"11"), 1), 0);
        assert!(!is_set(u(b"10"), 0) && !is_set(u(b"01"), 1), 1);
    }

    #[test]
    /// Verify correct returns
    fun is_out_success() {
        assert!(is_out(OUT << N_TYPE), 0);
        assert!(!is_out(0), 1);
    }

    #[test]
    /// Verify correct returns
    fun o_v_success() {
        assert!(o_v(OUT << N_TYPE) == 0, 0);
        assert!(o_v(OUT << N_TYPE | 123) == 123, 1); }

    #[test]
    /// Verify correct returns
    fun out_c_success() {
        assert!(o_c(0) == OUT << N_TYPE, 0);
        assert!(o_c(123) == OUT << N_TYPE | 123, 1);
    }

    #[test_only]
    /// Return a `u128` corresponding to the provided byte string. The
    /// byte should only contain only "0"s and "1"s, up to 128
    /// characters max (e.g. `b"100101...10101010"`)
    fun u(
        s: vector<u8>
    ): u128 {
        let n = v_l<u8>(&s); // Get number of bits
        let r = 0; // Initialize result to 0
        let i = 0; // Start loop at least significant bit
        while (i < n) { // While there are bits left to review
            let b = *v_b<u8>(&s, n - 1 - i); // Get bit under review
            if (b == 0x31) { // If the bit is 1 (0x31 in ASCII)
                // OR result with the correspondingly leftshifted bit
                r = r | 1 << (i as u8);
            // Otherwise, assert bit is marked 0 (0x30 in ASCII)
            } else assert!(b == 0x30, E_BIT_NOT_0_OR_1);
            i = i + 1; // Proceed to next-least-significant bit
        };
        r // Return result
    }

    #[test_only]
    /// Return `u128` corresponding to concatenated result of `a`, `b`,
    /// and `c`. Useful for line-wrapping long byte strings
    fun u_long(
        a: vector<u8>,
        b: vector<u8>,
        c: vector<u8>
    ): u128 {
        v_a<u8>(&mut b, c); // Append c onto b
        v_a<u8>(&mut a, b); // Append b onto a
        u(a) // Return u128 equivalent of concatenated bytestring
    }

    #[test]
    /// Verify successful return values
    fun u_success() {
        assert!(u(b"0") == 0, 0);
        assert!(u(b"1") == 1, 1);
        assert!(u(b"00") == 0, 2);
        assert!(u(b"01") == 1, 3);
        assert!(u(b"10") == 2, 4);
        assert!(u(b"11") == 3, 5);
        assert!(u(b"10101010") == 170, 6);
        assert!(u(b"00000001") == 1, 7);
        assert!(u(b"11111111") == 255, 8);
        assert!(u_long( // 60 characters on first two lines, 8 on last
            b"111111111111111111111111111111111111111111111111111111111111",
            b"111111111111111111111111111111111111111111111111111111111111",
            b"11111111"
        ) == HI_128, 9);
        assert!(u_long( // 60 characters on first two lines, 8 on last
            b"111111111111111111111111111111111111111111111111111111111111",
            b"111111111111111111111111111111111111111111111111111111111111",
            b"11111110"
        ) == HI_128 - 1, 10);
    }

    #[test]
    #[expected_failure(abort_code = 0)]
    /// Verify failure for non-binary-representative byte string
    fun u_failure() {u(b"2");}

    /// Return a bitmask with all bits high except for bit `b`,
    /// 0-indexed starting at LSB: bitshift 1 by `b`, XOR with `HI_128`
    fun b_lo(b: u8): u128 {1 << b ^ HI_128}

    #[test]
    /// Verify successful bitmask generation
    fun b_lo_success() {
        assert!(b_lo(0) == HI_128 - 1, 0);
        assert!(b_lo(1) == HI_128 - 2, 1);
        assert!(b_lo(127) == 0x7fffffffffffffffffffffffffffffff, 2);
    }

// Binary operation helper functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

// Initialization >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Return an empty tree
    public fun empty<V>():
    CB<V> {
        CB{r: 0, i: v_e<I>(), o: v_e<O<V>>()}
    }

    #[test]
    /// Verify new tree created empty
    fun empty_success():
    (
        vector<I>,
        vector<O<u8>>
    ) {
        // Unpack root index and node vectors
        let CB{r, i, o} = empty<u8>();
        assert!(v_i_e<I>(&i), 0); // Assert empty inner node vector
        assert!(v_i_e<O<u8>>(&o), 1); // Assert empty outer node vector
        assert!(r == 0, 0); // Assert root set to 0
        (i, o) // Return rather than unpack
    }

    /// Return a tree with one node having key `k` and value `v`
    public fun singleton<V>(
        k: u128,
        v: V
    ):
    CB<V> {
        let cb = CB{r: 0, i: v_e<I>(), o: v_e<O<V>>()};
        insert_empty<V>(&mut cb, k, v);
        cb
    }

    #[test]
    /// Verify singleton initialized with correct values
    fun singleton_success():
    (
        vector<I>,
        vector<O<u8>>,
    ) {
        let cb = singleton<u8>(2, 3); // Initialize w/ key 2 and value 3
        assert!(v_i_e<I>(&cb.i), 0); // Assert no inner nodes
        assert!(v_l<O<u8>>(&cb.o) == 1, 1); // Assert single outer node
        let CB{r, i, o} = cb; // Unpack root index and node vectors
        // Assert root index field indicates 0th outer node
        assert!(r == OUT << N_TYPE, 2);
        // Pop and unpack last node from vector of outer nodes
        let O{k, v, p} = v_po_b<O<u8>>(&mut o);
        // Assert values in node are as expected
        assert!(k == 2 && v == 3 && p == ROOT, 3);
        (i, o) // Return rather than unpack
    }

// Initialization <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

// Destruction >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Destroy empty tree `cb`
    public fun destroy_empty<V>(
        cb: CB<V>
    ) {
        assert!(is_empty(&cb), E_DESTROY_NOT_EMPTY);
        let CB{r: _, i, o} = cb; // Unpack root index and node vectors
        v_d_e(i); // Destroy empty inner node vector
        v_d_e(o); // Destroy empty outer node vector
    }

    #[test]
    /// Verify empty tree destruction
    fun destroy_empty_success() {
        let cb = empty<u8>(); // Initialize empty tree
        destroy_empty<u8>(cb); // Destroy it
    }

    #[test]
    #[expected_failure(abort_code = 1)]
    /// Verify cannot destroy non-empty tree
    fun destroy_empty_fail() {
        // Attempt destroying singleton
        destroy_empty<u8>(singleton<u8>(0, 0));
    }

// Destruction <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

// Size checks >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Return `true` if `cb` has no outer nodes
    public fun is_empty<V>(cb: &CB<V>): bool {v_i_e<O<V>>(&cb.o)}

    #[test]
    /// Verify emptiness check validity
    fun is_empty_success():
    CB<u8> {
        let cb = empty<u8>(); // Get empty tree
        assert!(is_empty<u8>(&cb), 0); // Assert is empty
        insert_empty<u8>(&mut cb, 1, 2); // Insert key 1 and value 2
        // Assert not marked empty
        assert!(!is_empty<u8>(&cb), 0);
        cb // Return rather than unpack
    }

    /// Return number of keys in `cb` (number of outer nodes)
    public fun length<V>(cb: &CB<V>): u64 {v_l<O<V>>(&cb.o)}

    #[test]
    /// Verify length check validity
    fun length_success():
    CB<u8> {
        let cb = empty(); // Initialize empty tree
        assert!(length<u8>(&cb) == 0, 0); // Assert length is 0
        insert(&mut cb, 1, 2); // Insert
        assert!(length<u8>(&cb) == 1, 1); // Assert length is 1
        insert(&mut cb, 3, 4); // Insert
        assert!(length<u8>(&cb) == 2, 2); // Assert length is 2
        cb // Return rather than unpack
    }

// Size checks >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

// Borrowing >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /*
    /// Return immutable reference to either left or right child of
    /// inner node `n` in `cb` (left if `d` is `L`, right if `d` is `R`)
    fun b_i_c<V>(
        cb: &CB<V>,
        n: &N<V>,
        d: bool
    ): &N<V> {
        if (d == L) v_b<N<V>>(&cb.t, n.l) else v_b<N<V>>(&cb.t, n.r)
    }

    /// Return mutable reference to the field where an inner node stores
    /// the index of either its left or right child (left if `d` is `L`,
    /// right if `d` is `R`). The inner node in question is borrowed by
    /// dereferencing a reference to the field where its own node index
    /// is stored, `i_f_r`, ("index field reference")
    fun b_c_i_f_r<V>(
        cb: &mut CB<V>,
        i_f_r: &mut u64,
        d: bool
    ): &mut u64 {
        if (d == L) &mut v_b_m<N<V>>(&mut cb.t, *i_f_r).l else
            &mut v_b_m<N<V>>(&mut cb.t, *i_f_r).r
    }
    */

    /// Return immutable reference to the outer node sharing the largest
    /// common prefix with `k` in non-empty tree `cb`. `b_c_o` indicates
    /// "borrow closest outer"
    fun b_c_o<V>(
        cb: &CB<V>,
        k: u128,
    ): &O<V> {
        // If root is an outer node, return reference to it
        if (is_out(cb.r)) return (v_b<O<V>>(&cb.o, o_v(cb.r)));
        // Otherwise borrow inner node at root
        let n = v_b<I>(&cb.i, cb.r);
        loop { // Loop over inner nodes
            // If key is set at critical bit, get index of child on R
            let i_c = if (is_set(k, n.c)) n.r else n.l; // Otherwise L
            // If child is outer node, return reference to it
            if (is_out(i_c)) return v_b<O<V>>(&cb.o, o_v(i_c));
            n = v_b<I>(&cb.i, i_c); // Borrow next inner node to review
        }
    }

    /// Return mutable reference to the outer node sharing the largest
    /// common prefix with `k` in non-empty tree `cb`. `b_c_o_m`
    /// indicates "borrow closest outer mutable"
    fun b_c_o_m<V>(
        cb: &mut CB<V>,
        k: u128,
    ): &mut O<V> {
        // If root is an outer node, return mutable reference to it
        if (is_out(cb.r)) return (v_b_m<O<V>>(&mut cb.o, o_v(cb.r)));
        // Otherwise borrow inner node at root
        let n = v_b<I>(&cb.i, cb.r);
        loop { // Loop over inner nodes
            // If key is set at critical bit, get index of child on R
            let i_c = if (is_set(k, n.c)) n.r else n.l; // Otherwise L
            // If child is outer node, return mutable reference to it
            if (is_out(i_c)) return v_b_m<O<V>>(&mut cb.o, o_v(i_c));
            n = v_b<I>(&cb.i, i_c); // Borrow next inner node to review
        }
    }

    /// Return immutable reference to value corresponding to key `k` in
    /// `cb`, aborting if empty tree or no match
    public fun borrow<V>(
        cb: &CB<V>,
        k: u128,
    ): &V {
        assert!(!is_empty<V>(cb), E_BORROW_EMPTY); // Abort if empty
        let c_o = b_c_o<V>(cb, k); // Borrow closest outer node
        assert!(c_o.k == k, E_NOT_HAS_K); // Abort if key not in tree
        &c_o.v // Return immutable reference to corresponding value
    }

    /// Return mutable reference to value corresponding to key `k` in
    /// `cb`, aborting if empty tree or no match
    public fun borrow_mut<V>(
        cb: &mut CB<V>,
        k: u128,
    ): &mut V {
        assert!(!is_empty<V>(cb), E_BORROW_EMPTY); // Abort if empty
        let c_o = b_c_o_m<V>(cb, k); // Borrow closest outer node
        assert!(c_o.k == k, E_NOT_HAS_K); // Abort if key not in tree
        &mut c_o.v // Return mutable reference to corresponding value
    }

    #[test]
    #[expected_failure(abort_code = 3)]
    /// Assert failure for attempted borrow on empty tree
    public fun borrow_empty():
    CB<u8> {
        let cb = empty<u8>(); // Initialize empty tree
        borrow<u8>(&cb, 0); // Attempt invalid borrow
        cb // Return rather than unpack (or signal to compiler as much)
    }

    #[test]
    #[expected_failure(abort_code = 3)]
    /// Assert failure for attempted borrow on empty tree
    public fun borrow_mut_empty():
    CB<u8> {
        let cb = empty<u8>(); // Initialize empty tree
        borrow_mut<u8>(&mut cb, 0); // Attempt invalid borrow
        cb // Return rather than unpack (or signal to compiler as much)
    }

    #[test]
    #[expected_failure(abort_code = 4)]
    /// Assert failure for attempted borrow without matching key
    public fun borrow_no_match():
    CB<u8> {
        let cb = singleton<u8>(3, 4); // Initialize singleton
        borrow<u8>(&cb, 6); // Attempt invalid borrow
        cb // Return rather than unpack (or signal to compiler as much)
    }

    #[test]
    #[expected_failure(abort_code = 4)]
    /// Assert failure for attempted borrow without matching key
    public fun borrow_mut_no_match():
    CB<u8> {
        let cb = singleton<u8>(3, 4); // Initialize singleton
        borrow_mut<u8>(&mut cb, 6); // Attempt invalid borrow
        cb // Return rather than unpack (or signal to compiler as much)
    }

    #[test]
    /// Assert correct modification of values
    public fun borrow_mut_success():
    CB<u8> {
        let cb = empty<u8>(); // Initialize empty tree
        // Insert assorted key-value pairs
        insert(&mut cb, 2, 6);
        insert(&mut cb, 3, 8);
        insert(&mut cb, 1, 9);
        insert(&mut cb, 7, 5);
        // Modify some of the values
        *borrow_mut<u8>(&mut cb, 1) = 2;
        *borrow_mut<u8>(&mut cb, 2) = 4;
        // Assert values are as expected
        assert!(*borrow<u8>(&mut cb, 2) == 4, 0); // Changed
        assert!(*borrow<u8>(&mut cb, 3) == 8, 0); // Unchanged
        assert!(*borrow<u8>(&mut cb, 1) == 2, 0); // Changed
        assert!(*borrow<u8>(&mut cb, 7) == 5, 0); // Unchanged
        cb // Return rather than unpack
    }

    /*
    /// Return same as `b_c_o`, but also return mutable reference to the
    /// field that stores the node vector index of the outer node
    /// sharing the largest common prefix with `k` in `cb` (an "index
    /// field reference", analagous to a pointer to the closest outer
    /// node)
    fun b_c_o_i_f_r<V>(
        cb: &mut CB<V>,
        k: u128,
    ): (
        &N<V>,
        &mut u64
    ) {
        // Get mutable reference to the field where a node's vector
        // index is stored ("index field reference"), starting at root
        let i_f_r = &mut cb.r;
        let n = v_b<N<V>>(&cb.t, *i_f_r); // Get root node reference
        while (n.c != OUT) { // While node under review is inner node
            // Borrow mutable reference to the field that stores the
            // vector index of the node's L or R child node, depending
            // on AND result discussed in `b_c_o`
            i_f_r = b_c_i_f_r<V>(cb, i_f_r, n.s & k == 0);
            // Get reference to new node under review
            n = v_b<N<V>>(&cb.t, *i_f_r);
        }; // Index field reference is now that of closest outer node
        // Return closest outer node reference, and corresponding index
        // field reference (analagous to a pointer to the node)
        (n, i_f_r)
    }
    */

// Borrowing <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

// Membership checks >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Return true if `cb` has key `k`
    fun has_key<V>(
        cb: &CB<V>,
        k: u128,
    ): bool {
        if (is_empty<V>(cb)) return false; // Return false if empty
        // Return true if closest outer node has same key
        return b_c_o<V>(cb, k).k == k
    }

    #[test]
    /// Verify returns `false` for empty tree
    fun has_key_empty_success() {
        let cb = empty<u8>(); // Initialize empty tree
        assert!(!has_key(&cb, 0), 0); // Assert key check returns false
        destroy_empty<u8>(cb); // Drop empty tree
    }

    #[test]
    /// Verify successful key checks for the following tree, where `i_i`
    /// indicates an inner node's vector index, and `o_i` indicates an
    /// outer node's vector index:
    /// ```
    /// >           i_i = 0 -> 2nd
    /// >                     /   \
    /// >        o_i = 0 -> 001   1st <- i_i = 1
    /// >                        /   \
    /// >           o_i = 1 -> 101   0th <- i_i = 2
    /// >                           /   \
    /// >              o_i = 2 -> 110   111 <- o_i = 3
    /// ```
    fun has_key_success():
    CB<u8> {
        let v = 0; // Ignore values in key-value pairs by setting to 0
        let cb = empty<u8>(); // Initialize empty tree
        // Append nodes per above tree
        v_pu_b<I>(&mut cb.i, I{c: 2, p: ROOT, l: o_c(0), r:     1 });
        v_pu_b<I>(&mut cb.i, I{c: 1, p:    0, l: o_c(1), r:     2 });
        v_pu_b<I>(&mut cb.i, I{c: 0, p:    1, l: o_c(2), r: o_c(3)});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"001"), v, p: 0});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"101"), v, p: 1});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"110"), v, p: 2});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"111"), v, p: 2});
        // Assert correct membership checks
        assert!(has_key(&cb, u(b"001")), 0);
        assert!(has_key(&cb, u(b"101")), 1);
        assert!(has_key(&cb, u(b"110")), 2);
        assert!(has_key(&cb, u(b"111")), 3);
        assert!(!has_key(&cb, u(b"011")), 4); // Not in tree
        cb // Return rather than unpack
    }

    #[test]
    /// Verify successful key checks in special case of singleton tree
    fun has_key_singleton():
    CB<u8> {
        // Create singleton with key 1 and value 2
        let cb = singleton<u8>(1, 2);
        assert!(has_key(&cb, 1), 0); // Assert key of 1 registered
        assert!(!has_key(&cb, 3), 0); // Assert key of 3 not registered
        cb // Return rather than unpack
    }

// Membership checks <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

// Searching >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Walk from root tree `cb` having an inner node as its root,
    /// branching left or right at each inner node depending on whether
    /// `k` is unset or set, respectively, at the given critical bit.
    /// After arriving at an outer node, then return:
    /// * `u64`: index of searched outer node (with node type bit flag)
    /// * `bool`: the side, `L` or `R`, on which the searched outer node
    ///    is a child of its parent
    /// * `u128`: key of searched outer node
    /// * `u64`: vector index of parent to searched outer node
    /// * `&mut O<V>`: mutable reference to searched outer node
    fun search_outer<V>(
        cb: &mut CB<V>,
        k: u128
    ): (
        u64,
        bool,
        u128,
        u64,
        &mut O<V>,
    ) {
        let s_p = v_b<I>(&cb.i, 0); // Initialize search parent to root
        loop { // Loop over inner nodes until branching to outer node
            // If key set at critical bit, track field index and side of
            // R child, else L
            let (i, s) = if (is_set(k, s_p.c)) (s_p.r, R) else (s_p.l, L);
            if (is_out(i)) { // If child is outer node
                // Borrow immutable reference to it
                let s_o = v_b_m<O<V>>(&mut cb.o, o_v(i));
                // Return field index of searched outer node, its side
                // as a child, its key, the vector index of its parent,
                // and a mutable reference to it
                return (i, s, s_o.k, s_o.p, s_o)
            };
            s_p = v_b<I>(&cb.i, i); // Search next inner node
        }
    }

// Searching <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

// Insertion >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Insert key-value pair `k` and `v` into an empty `cb`
    fun insert_empty<V>(
        cb: &mut CB<V>,
        k: u128,
        v: V
    ) {
        // Push back outer node onto tree's vector of outer nodes
        v_pu_b<O<V>>(&mut cb.o, O<V>{k, v, p: ROOT});
        // Set root index field to indicate 0th outer node
        cb.r = OUT << N_TYPE;
    }

    /// Insert key `k` and value `v` into singleton tree `cb`, a special
    /// case that that requires updating the root field of the tree,
    /// aborting if `k` already in `cb`
    fun insert_singleton<V>(
        cb: &mut CB<V>,
        k: u128,
        v: V
    ) {
        let n = v_b<O<V>>(&cb.o, 0); // Borrow existing outer node
        assert!(k != n.k, E_HAS_K); // Assert insertion key not in tree
        let c = crit_bit(n.k, k); // Get critical bit between two keys
        // If insertion key greater than existing key, new inner node at
        // root should have existing key as left child and insertion key
        // as right child, otherwise the opposite
        let (l, r) = if (k > n.k) (o_c(0), o_c(1)) else (o_c(1), o_c(0));
        // Push back new inner node with corresponding children
        v_pu_b<I>(&mut cb.i, I{c, p: ROOT, l, r});
        // Update existing outer node to have new inner node as parent
        v_b_m<O<V>>(&mut cb.o, 0).p = 0;
        // Push back new outer node onto outer node vector
        v_pu_b<O<V>>(&mut cb.o, O<V>{k, v, p: 0});
        // Update tree root field for newly-created inner node
        cb.r = 0;
    }

    #[test]
    /// Verify proper insertion result for insertion to left:
    /// ```
    /// >      1111     Insert         1st
    /// >                1101         /   \
    /// >               ----->    1101     1111
    /// ```
    fun insert_singleton_success_left():
    (
        CB<u8>
    ) {
        let cb = singleton<u8>(u(b"1111"), 4); // Initialize singleton
        insert_singleton(&mut cb, u(b"1101"), 5); // Insert to left
        assert!(cb.r == 0, 0); // Assert root is at new inner node
        let i = v_b<I>(&cb.i, 0); // Borrow inner node at root
        // Assert root inner node values are as expected
        assert!(i.c == 1 && i.p == ROOT && i.l == o_c(1) && i.r == o_c(0), 1);
        let o_o = v_b<O<u8>>(&cb.o, 0); // Borrow original outer node
        // Assert original outer node values are as expected
        assert!(o_o.k == u(b"1111") && o_o.v == 4 && o_o.p == 0, 2);
        let n_o = v_b<O<u8>>(&cb.o, 1); // Borrow new outer node
        // Assert new outer node values are as expected
        assert!(n_o.k == u(b"1101") && n_o.v == 5 && n_o.p == 0, 3);
        cb // Return rather than unpack
    }

    #[test]
    /// Verify proper insertion result for insertion to right:
    /// ```
    /// >      1011     Insert         2nd
    /// >                1111         /   \
    /// >               ----->    1011     1111
    /// ```
    fun insert_singleton_success_right():
    CB<u8> {
        let cb = singleton<u8>(u(b"1011"), 6); // Initialize singleton
        insert_singleton(&mut cb, u(b"1111"), 7); // Insert to right
        assert!(cb.r == 0, 0); // Assert root is at new inner node
        let i = v_b<I>(&cb.i, 0); // Borrow inner node at root
        // Assert root inner node values are as expected
        assert!(i.c == 2 && i.p == ROOT && i.l == o_c(0) && i.r == o_c(1), 1);
        let o_o = v_b<O<u8>>(&cb.o, 0); // Borrow original outer node
        // Assert original outer node values are as expected
        assert!(o_o.k == u(b"1011") && o_o.v == 6 && o_o.p == 0, 2);
        let n_o = v_b<O<u8>>(&cb.o, 1); // Borrow new outer node
        // Assert new outer node values are as expected
        assert!(n_o.k == u(b"1111") && n_o.v == 7 && o_o.p == 0, 3);
        cb // Return rather than unpack
    }

    #[test]
    #[expected_failure(abort_code = 2)]
    /// Verify failure for attempting duplicate insertion on singleton
    fun insert_singleton_failure():
    CB<u8> {
        let cb = singleton<u8>(1, 2); // Initialize singleton
        insert_singleton(&mut cb, 1, 5); // Attempt to insert same key
        cb // Return rather than unpack (or signal to compiler as much)
    }

    /// Insert key `k` and value `v` into tree `cb` already having `n_o`
    /// keys for general case where root is an inner node, aborting if
    /// `k` is already present. First, perform an outer node search and
    /// identify the critical bit of divergence between the searched
    /// outer node and `k`. Then walk back up the tree, inserting a new
    /// inner node at the appropriate position. In the case of inserting
    /// a new inner node directly above the searched outer node, the
    /// searched outer node must be updated to have as its parent the
    /// new inner node, and the search parent node must be updated to
    /// have as its child the new inner node where the searched outer
    /// node previously was:
    /// ```
    /// >       2nd
    /// >      /   \
    /// >    001   1st <- search parent
    /// >         /   \
    /// >       101   111 <- search outer node
    /// >
    /// >       Insert 110
    /// >       --------->
    /// >
    /// >                  2nd
    /// >                 /   \
    /// >               001   1st <- search parent
    /// >                    /   \
    /// >                  101   0th <- new inner node
    /// >                       /   \
    /// >   new outer node -> 110   111 <- search outer node
    /// ```
    /// In the case of inserting a new inner node above the search
    /// parent when the search parent is the root, the new inner node
    /// becomes the root and has as its child the new outer node:
    /// ```
    /// >          0th <- search parent
    /// >         /   \
    /// >       101   111 <- search outer node
    /// >
    /// >       Insert 011
    /// >       --------->
    /// >
    /// >                         2nd <- new inner node
    /// >                        /   \
    /// >    new outer node -> 011   0th <- search parent
    /// >                           /   \
    /// >                         101   111 <- search outer node
    /// ```
    /// In the case of inserting a new inner node above the search
    /// parent when the search parent is not the root:
    /// ```
    /// >
    /// >           2nd
    /// >          /   \
    /// >        011   0th <- search parent
    /// >             /   \
    /// >           101   111 <- search outer node
    /// >
    /// >       Insert 100
    /// >       --------->
    /// >
    /// >                       2nd
    /// >                      /   \
    /// >                    001   1st <- new inner node
    /// >                         /   \
    /// >     new outer node -> 100   0th <- search parent
    /// >                            /   \
    /// >                          110   111 <- search outer node
    /// ```
    fun insert_general<V>(
        cb: &mut CB<V>,
        k: u128,
        v: V,
        n_o: u64
    ) {
        // Get number of inner nodes in tree (index of new inner node)
        let i_n_i = v_l<I>(&cb.i);
        // Get field index of searched outer node, its side as a child,
        // its key, the vector index of its parent, and borrow a mutable
        // reference to it
        let (i_s_o, s_s_o, k_s_o, i_s_p, s_o) = search_outer(cb, k);
        assert!(k_s_o != k, E_HAS_K); // Assert key not a duplicate
        // Set searched outer node to have as its parent new inner node
        s_o.p = i_n_i;
        // Borrow mutable reference to search parent
        let s_p = v_b_m<I>(&mut cb.i, i_s_p);
        // Update search parent to have as a child the new inner node,
        // on the same side that the searched outer node was a child at
        if (s_s_o == L) s_p.l = i_n_i else s_p.r = i_n_i;
        let c = crit_bit(k_s_o, k); // Get critical bit of divergence
        // If insertion key less than searched outer key, declare left
        // child field (for new inner node) as new outer node and right
        // child field as searched outer node, else flip the positions
        let (l, r) = if (k < k_s_o) (o_c(n_o), i_s_o) else (i_s_o, o_c(n_o));
        // Push back new inner node having search parent as its parent
        v_pu_b<I>(&mut cb.i, I{c, p: i_s_p, l, r});
        // Push back new outer node having new inner node as parent
        v_pu_b<O<V>>(&mut cb.o, O{k, v, p: i_n_i});
    }

    #[test]
    /// Verify proper restructuring of tree for inserting key to left of
    /// new inner node, where new inner node is inserted to right of
    /// closest parent. `CON` indicates closest outer node, `CP`
    /// indicates closest parent, `NIN` indicates new inner node, `NON`
    /// indicates new outer node, `i_i` indicates an inner node's vector
    /// index, and `o_i` indicates an outer node's vector index:
    /// ```
    /// >      i_i = 0 -> 2nd
    /// >                /   \
    /// >   o_i = 0 -> 001   1st <- i_i = 1 (CP)
    /// >                   /   \
    /// >      o_i = 1 -> 101   111 <- o_i = 2 (CON)
    /// >
    /// >                     Insert 110
    /// >                     --------->
    /// >
    /// >      i_i = 0 -> 2nd
    /// >                /   \
    /// >   o_i = 0 -> 001   1st <- i_i = 1 (CP)
    /// >                   /   \
    /// >      o_i = 1 -> 101   0th <- i_i = 2 (NIN)
    /// >                      /   \
    /// >   (NON) o_i = 3 -> 110   111 <- o_i = 2 (CON)
    /// ```
    fun insert_general_success_1():
    CB<u8> {
        let v = 0; // Ignore values in key-value pairs by setting to 0
        let cb = empty<u8>(); // Initialize empty tree
        // Append nodes per above tree, pre-insertion
        v_pu_b<I>(&mut cb.i, I{c: 2, p: ROOT, l: o_c(0), r:     1 });
        v_pu_b<I>(&mut cb.i, I{c: 1, p:    0, l: o_c(1), r: o_c(2)});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"001"), v, p: 0});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"101"), v, p: 1});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"111"), v, p: 1});
        // Insert new key
        insert_general<u8>(&mut cb, u(b"110"), v, 3);
        // Assert closest parent now reflects new inner node as R child
        assert!(v_b<I>(&cb.i, 1).r == 2, 0);
        let n_i = v_b<I>(&cb.i, 2); // Borrow new inner node
        // Assert correct fields for new inner node
        assert!(
            n_i.c == 0 && n_i.p == 1 && n_i.l == o_c(3) && n_i.r == o_c(2), 1
        );
        let n_o = v_b<O<u8>>(&cb.o, 3); // Borrow new outer node
        // Assert correct fields for new outer node
        assert!(n_o.k == u(b"110") && n_o.p == 2, 2);
        // Assert closest outer node now has new inner node as parent
        assert!(v_b<O<u8>>(&cb.o, 2).p == 2, 3);
        cb // Return rather than unpack
    }

    #[test]
    /// Like `insert_general_success_1`, but for `NIN` to left of `CP`
    /// and `NON` to right of `NIN`
    /// ```
    /// >       (CP) i_i = 0 -> 1st
    /// >                      /   \
    /// >   (CON) o_i = 0 -> 00     10 <- o_i = 1
    /// >
    /// >                  Insert 01
    /// >                  -------->
    /// >
    /// >          (CP) i_i = 0 -> 1st
    /// >                         /   \
    /// >      (NIN) i_i = 1 -> 0th    10 <- o_i = 1
    /// >                      /   \
    /// >   (CON) o_i = 0 -> 00     01 <- o_i = 2 (NON)
    /// ```
    fun insert_general_success_2():
    CB<u8> {
        let v = 0; // Ignore values in key-value pairs by setting to 0
        let cb = empty<u8>(); // Initialize empty tree
        // Append nodes per above tree, pre-insertion
        v_pu_b<I>(&mut cb.i, I{c: 1, p: ROOT, l: o_c(0), r: o_c(1)});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"00"), v, p: 0});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"10"), v, p: 0});
        // Insert new key
        insert_general<u8>(&mut cb, u(b"01"), v, 2);
        // Assert closest parent now reflects new inner node as L child
        assert!(v_b<I>(&cb.i, 0).l == 1, 0);
        let n_i = v_b<I>(&cb.i, 1); // Borrow new inner node
        // Assert correct fields for new inner node
        assert!(
            n_i.c == 0 && n_i.p == 0 && n_i.l == o_c(0) && n_i.r == o_c(2), 1
        );
        let n_o = v_b<O<u8>>(&cb.o, 2); // Borrow new outer node
        // Assert correct fields for new outer node
        assert!(n_o.k == u(b"01") && n_o.p == 1, 2);
        // Assert closest outer node now has new inner node as parent
        assert!(v_b<O<u8>>(&cb.o, 0).p == 1, 3);
        cb // Return rather than unpack
    }

    #[test]
    #[expected_failure(abort_code = 2)]
    /// Verify aborts when key already in tree
    fun insert_general_failure():
    CB<u8> {
        let cb = singleton<u8>(3, 4); // Initialize singleton
        insert_singleton(&mut cb, 5, 6); // Insert onto singleton
        // Attempt insert for general case, but with duplicate key
        insert_general(&mut cb, 5, 7, 2);
        cb // Return rather than unpack (or signal to compiler as much)
    }

    /// Insert key `k` and value `v` into `cb`, aborting if `k` already
    /// in `cb`
    public fun insert<V>(
        cb: &mut CB<V>,
        k: u128,
        v: V
    ) {
        let l = length(cb); // Get length of tree
        check_len(l); // Verify insertion can take place
        // Insert via one of three cases, depending on the length
        if (l == 0) insert_empty(cb, k , v) else
        if (l == 1) insert_singleton(cb, k, v) else
        insert_general(cb, k , v, l);
    }

    #[test]
    /// Verify correct lookup post-insertion
    fun insert_success():
    CB<u8> {
        let cb = empty(); // Initialize empty tree
        // Insert various key-value pairs
        insert(&mut cb, 5, 35);
        insert(&mut cb, 7, 73);
        insert(&mut cb, 1, 99);
        insert(&mut cb, 8, 44);
        // Verify key-value lookup
        assert!(*borrow(&cb, 8) == 44, 0);
        assert!(*borrow(&cb, 1) == 99, 1);
        assert!(*borrow(&cb, 7) == 73, 2);
        assert!(*borrow(&cb, 5) == 35, 3);
        cb // Return rather than unpack
    }

    /// Assert that `l` is less than the value indicated by a bitmask
    /// where only the 63rd bit is not set (this bitmask corresponds to
    /// the maximum number of keys that can be stored in a tree, since
    /// the 63rd bit is reserved for the node type bit flag)
    fun check_len(l: u64) {assert!(l < HI_64 ^ OUT << N_TYPE, E_INSERT_FULL);}

    #[test]
    /// Verify length check passes for valid sizes
    fun check_len_success() {
        check_len(0);
        check_len(1200);
        // Maximum number of keys that can be in tree pre-insert
        check_len((HI_64 ^ OUT << N_TYPE) - 1);
    }

    #[test]
    #[expected_failure(abort_code = 5)]
    /// Verify length check fails for too many elements
    fun check_len_failure() {
        check_len(HI_64 ^ OUT << N_TYPE); // Tree is full
    }

// Insertion <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

// Popping >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    /// Return the value corresponding to key `k` in tree `cb` and
    /// destroy the outer node where it was stored, for the special case
    /// of a singleton tree. Abort if `k` not in `cb`
    fun pop_singleton<V>(
        cb: &mut CB<V>,
        k: u128
    ): V {
        // Assert key actually in tree at root node
        assert!(v_b<O<V>>(&cb.o, 0).k == k, E_NOT_HAS_K);
        cb.r = 0; // Update root
        // Pop off and destruct outer node at root
        let O{k: _, v, p: _} = v_po_b<O<V>>(&mut cb.o);
        v // Return popped value
    }

    #[test]
    // Verify successful pop
    fun pop_singleton_success() {
        let cb = singleton(1, 2); // Initialize singleton
        assert!(pop_singleton(&mut cb, 1) == 2, 0); // Verify pop value
        assert!(is_empty(&mut cb), 1); // Assert marked as empty
        assert!(cb.r == 0, 2); // Assert root index field updated
        destroy_empty<u8>(cb); // Destroy empty tree
    }

    #[test]
    #[expected_failure(abort_code = 4)]
    // Verify pop failure when key not in tree
    fun pop_singleton_failure():
    CB<u8> {
        let cb = singleton(1, 2); // Initialize singleton
        let _ = pop_singleton<u8>(&mut cb, 3); // Attempt invalid pop
        cb // Return rather than unpack (or signal to compiler as much)
    }

    /// Return the value corresponding to key `k` in tree `cb` and
    /// destroy the outer node where it was stored, for the special case
    /// of a tree having height one. Abort if `k` not in `cb`
    fun pop_height_one<V>(
        cb: &mut CB<V>,
        k: u128
    ): V {
        let r = v_b_m<I>(&mut cb.i, 0); // Borrow inner node at root
        // If pop key is set at critical bit, mark outer node to destroy
        // as the root's right child and mark the outer node to keep
        // as the root's left child, otherwise the opposite
        let (o_d, o_k) =
            if(is_set(k, r.c)) (o_v(r.r), o_v(r.l)) else (o_v(r.l), o_v(r.r));
        // Assert key is actually in tree
        assert!(v_b<O<V>>(&cb.o, o_d).k == k, E_NOT_HAS_K);
        // Destroy inner node at root
        let I{c: _, p: _, l: _, r: _} = v_po_b<I>(&mut cb.i);
        // Update kept outer node parent field to indicate it is root
        v_b_m<O<V>>(&mut cb.o, o_k).p = ROOT;
        // Swap remove outer node to destroy, storing only its value
        let O{k: _, v, p: _} = v_s_r<O<V>>(&mut cb.o, o_d);
        // Update root index field to indicate kept outer node
        cb.r = OUT << N_TYPE;
        v // Return popped value
    }

    /// Return the value corresponding to key `k` in tree `cb` having
    /// `n_o` keys and destroy the outer node where it was stored, for
    /// the general case of a tree with more than one outer node. Abort
    /// if `k` not in `cb`. Here, the parent of the popped node must be
    /// removed, and if the popped node has a grandparent, the
    /// grandparent of the popped node must be updated to have as its
    /// child the popped node's sibling at the same position where the
    /// popped node's parent previously was, whether the sibling is an
    /// outer or inner node. Likewise the sibling must be updated to
    /// have as its parent the grandparent to the popped node. Outer
    /// node sibling case:
    /// ```
    /// >              2nd <- grandparent
    /// >             /   \
    /// >           001   1st <- parent
    /// >                /   \
    /// >   sibling -> 101   111 <- popped node
    /// >
    /// >       Pop 111
    /// >       ------>
    /// >
    /// >                  2nd <- grandparent
    /// >                 /   \
    /// >               001    101 <- sibling
    /// ```
    /// Inner node sibling case:
    /// ```
    /// >              2nd <- grandparent
    /// >             /   \
    /// >           001   1st <- parent
    /// >                /   \
    /// >   sibling -> 0th   111 <- popped node
    /// >             /   \
    /// >           100   101
    /// >
    /// >       Pop 111
    /// >       ------>
    /// >
    /// >              2nd <- grandparent
    /// >             /   \
    /// >           001   0th <- sibling
    /// >                /   \
    /// >              100   101
    /// ```
    /// If the popped node does not have a grandparent (if its parent is
    /// the root node), then the root node must be removed and the
    /// popped node's sibling must become the new root, whether the
    /// sibling is an inner or outer node. Likewise the sibling must be
    /// updated to indicate that it is the root. Inner node sibling
    /// case:
    /// ```
    /// >                     2nd <- parent
    /// >                    /   \
    /// >   popped node -> 001   1st <- sibling
    /// >                       /   \
    /// >                     101   111
    /// >
    /// >       Pop 001
    /// >       ------>
    /// >
    /// >                  1st <- sibling
    /// >                 /   \
    /// >               101    111
    /// ```
    /// Outer node sibling case:
    /// ```
    /// >                     2nd <- parent
    /// >                    /   \
    /// >   popped node -> 001   101 <- sibling
    /// >
    /// >       Pop 001
    /// >       ------>
    /// >
    /// >                  101 <- sibling
    /// ```
    fun pop_general<V>(
        cb: &mut CB<V>,
        k: u128,
        n_o: u64
    ): V {
        // Get field index of searched outer node, its side as a child,
        // its key, and the vector index of its parent
        let (i_s_o, s_s_o, k_s_o, i_s_p, _) = search_outer(cb, k);
        assert!(k_s_o == k, E_NOT_HAS_K); // Assert key in tree
        let n_i = v_l<I>(&cb.i); // Get number of inner nodes pre-pop
        // Borrow immutable reference to popped node's parent
        let p = v_b<I>(&cb.i, i_s_p);
        // If popped outer node was a left child, store the right child
        // field index of its parent as the child field index of the
        // popped node's sibling. Else flip the direction
        let i_s = if (s_s_o == L) p.r else p.l;
        // Get parent field index of parent of popped node
        let i_p_p = p.p;
        // Update popped node's sibling to have at its parent index
        // field the same index as the popped node's parent, whether
        // the sibling is an inner or outer node
        if (is_out(i_s)) v_b_m<O<V>>(&mut cb.o, o_v(i_s)).p = i_p_p
            else v_b_m<I>(&mut cb.i, i_s).p = i_p_p;
        if (i_p_p == ROOT) { // If popped node's parent is root
            // Set root field index to index of popped node's sibling
            cb.r = i_s;
        } else { // If popped node has a grandparent
            // Borrow mutable reference to popped node's grandparent
            let g_p = v_b_m<I>(&mut cb.i, i_p_p);
            // If popped node's parent was a left child, update popped
            // node's grandparent to have as its child the popped node's
            // sibling. Else the right child
            if (g_p.l == i_s_p) g_p.l = i_s else g_p.r = i_s;
        };
        // Swap remove popped outer node, storing only its value
        let O{k: _, v, p: _} = v_s_r<O<V>>(&mut cb.o, o_v(i_s_o));
        // If destroyed outer node was not last outer node in vector,
        // repair the parent-child relationship broken by swap remove
        if (o_v(i_s_o) < n_o - 1) stitch_swap_remove(cb, i_s_o, n_o);
        // Swap remove parent of popped outer node, storing no fields
        let I{c: _, p: _, l: _, r: _} = v_s_r<I>(&mut cb.i, i_s_p);
        // If destroyed inner node was not last inner node in vector,
        // repair the parent-child relationship broken by swap remove
        if (i_s_p < n_i - 1) stitch_swap_remove(cb, i_s_p, n_i);
        v // Return popped value
    }

    #[test]
    /// Verify correct pop result and node updates, for `o_i` indicating
    /// outer node vector index and `i_i` indicating inner node vector
    /// index:
    /// ```
    /// >                  2nd <- i_i = 1
    /// >                 /   \
    /// >    o_i = 2 -> 001   1st <- i_i = 0
    /// >                    /   \
    /// >       o_i = 1 -> 101   111 <- o_i = 0
    /// >
    /// >       Pop 111
    /// >       ------>
    /// >
    /// >                  2nd  <- i_i = 0
    /// >                 /   \
    /// >    o_i = 0 -> 001   101 <- o_i = 1
    /// ```
    fun pop_general_success_1():
    CB<u8> {
        // Initialize singleton for node to be popped
        let cb = singleton(u(b"111"), 7);
        // Insert sibling, generating inner node marked 1st
        insert(&mut cb, u(b"101"), 8);
        // Insert key 001, generating new inner node marked 2nd, at root
        insert(&mut cb, u(b"001"), 9);
        // Assert correct pop value for key 111
        assert!(pop_general(&mut cb, u(b"111"), 3) == 7, 0);
        assert!(cb.r == 0, 1); // Assert root field updated
        let r = v_b<I>(&mut cb.i, 0); // Borrow inner node at root
        // Assert root inner node fields are as expected
        assert!(r.c == 2 && r.p == ROOT && r.l == o_c(0) && r.r == o_c(1), 2);
        let o_l = v_b<O<u8>>(&mut cb.o, 0); // Borrow outer node on left
        // Assert left outer node fields are as expected
        assert!(o_l.k == u(b"001") && o_l.v == 9 && o_l.p == 0, 3);
        let o_r = v_b<O<u8>>(&mut cb.o, 1); // Borrow outer node on right
        // Assert right outer node fields are as expected
        assert!(o_r.k == u(b"101") && o_r.v == 8 && o_r.p == 0, 4);
        cb // Return rather than unpack
    }

    #[test]
    /// Variation on `pop_general_success_1`:
    /// ```
    /// >                    2nd <- i_i = 2
    /// >                   /   \
    /// >      i_i = 1 -> 1st   111 <- o_i = 3
    /// >                /   \
    /// >   o_i = 2 -> 001   0th <- i_i = 0
    /// >                   /   \
    /// >     o_i = 1 ->  010    011 <- o_i = 0
    /// >
    /// >       Pop 001
    /// >       ------>
    /// >
    /// >                    2nd  <- i_i = 1
    /// >                   /   \
    /// >      o_i = 0 -> 0th   111 <- o_i = 2
    /// >                /   \
    /// >   o_i = 1 -> 010   011 <- o_i = 0
    /// ```
    fun pop_general_success_2():
    CB<u8> {
        // Initialize singleton with key 011
        let cb = singleton(u(b"011"), 5);
        // Insert key 010, generating new inner node with critbit = 0
        insert(&mut cb, u(b"010"), 6);
        // Insert key 001, generating new inner node with critbit = 1
        insert(&mut cb, u(b"001"), 8);
        // Insert key 111, generating new inner node with critbit = 2
        insert(&mut cb, u(b"111"), 7);
        assert!(cb.r == 0, 1);
        cb // Return rather than unpack
    }

    /// Repair a broken parent-child relationship in `cb` caused by
    /// swap removing, for relocated node now at index indicated by
    /// child field index `i_n`, in vector that contained `n_n` nodes
    /// before the swap remove (when relocated node was last in vector)
    fun stitch_swap_remove<V>(
        cb: &mut CB<V>,
        i_n: u64,
        n_n: u64
    ) {
        // If child field index indicates relocated outer node
        if (is_out(i_n)) {
            // Get index of parent to relocated node
            let i_p = v_b<O<V>>(&cb.o, o_v(i_n)).p;
            // Update parent to reflect relocated node position
            stitch_child_of_parent<V>(cb, i_n, i_p, o_c(n_n - 1));
        } else { // If child field index indicates relocated inner node
            // Borrow mutable reference to it
            let n = v_b<I>(&cb.i, i_n);
            // Get field index of node's parent and children
            let (i_p, i_l, i_r) = (n.p, n.l, n.r);
            // Update children to have relocated node as their parent
            stitch_parent_of_child(cb, i_n, i_l); // Left child
            stitch_parent_of_child(cb, i_n, i_r); // Right child
            // If root node relocated, update root field and return
            if (i_p == ROOT) {cb.r = i_n; return};
            // Else update parent to reflect relocated node position
            stitch_child_of_parent<V>(cb, i_n, i_p, n_n - 1);
        }
    }

    /// Update child node at child field index `i_c` in `cb` to reflect
    /// as its parent an inner node that has be relocated to child field
    /// index `i_n`
    fun stitch_parent_of_child<V>(
        cb: &mut CB<V>,
        i_n: u64,
        i_c: u64
    ) {
        // If child is an outer node, borrow corresponding node and
        // update its parent field index to that of relocated node
        if (is_out(i_c)) v_b_m<O<V>>(&mut cb.o, o_v(i_c)).p = i_n
            // Otherwise perform opdate on an inner node
            else v_b_m<I>(&mut cb.i, i_c).p = i_n;
    }

    /// Update parent node at index `i_p` in `cb` to reflect as its
    /// child a node that has been relocated from old child field index
    /// `i_o` to new child field index `i_n`
    fun stitch_child_of_parent<V>(
        cb: &mut CB<V>,
        i_n: u64,
        i_p: u64,
        i_o: u64
    ) {
        // Borrow mutable reference to parent
        let p = v_b_m<I>(&mut cb.i, i_p);
        // If relocated node was previously left child, update
        // parent's left child to indicate the relocated node's new
        // position, otherwise do update for right child of parent
        if (p.l == i_o) p.l = i_n else p.r = i_n;
    }

    #[test]
    /// Verify successful stitch for relocated left child outer node.
    /// `o_i` indicates outer index, `i_i` indicates inner index:
    /// ```
    /// >                          2nd <- i_i = 0
    /// >                         /   \
    /// >            o_i = 0 -> 001   1st <- i_i = 1
    /// >                            /   \
    /// >   (relocated) o_i = 3 -> 101   111 <- o_i = 1
    /// ```
    fun stitch_swap_remove_o_l():
    CB<u8> {
        let v = 0; // Ignore values in key-value pairs by setting to 0
        let cb = empty<u8>(); // Initialize empty tree
        // Append nodes per above tree, including bogus outer node at
        // vector index 2, which will be swap removed
        v_pu_b<I>(&mut cb.i, I{c: 2, p: ROOT, l: o_c(0), r:     1 });
        v_pu_b<I>(&mut cb.i, I{c: 1, p:    0, l: o_c(3), r: o_c(1)});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"001"), v, p: 0});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"111"), v, p: 1});
        v_pu_b<O<u8>>(&mut cb.o, O{k:    HI_128, v, p: HI_64}); // Bogus
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"101"), v, p: 1});
        // Swap remove and destruct bogus node
        let O{k: _, v: _, p: _} = v_s_r<O<u8>>(&mut cb.o, 2);
        // Stitch broken relationship
        stitch_swap_remove(&mut cb, o_c(2), 4);
        // Assert parent to relocated node indicates proper child update
        assert!(v_b<I>(&cb.i, 1).l == o_c(2), 0);
        cb // Return rather than unpack
    }

    #[test]
    /// Verify successful stitch for relocated right child outer node.
    /// `o_i` indicates outer index, `i_i` indicates inner index:
    /// ```
    /// >                2nd <- i_i = 0
    /// >               /   \
    /// >  o_i = 0 -> 001   1st <- i_i = 1
    /// >                  /   \
    /// >     o_i = 1 -> 101   111 <- o_i = 3 (relocated)
    /// ```
    fun stitch_swap_remove_o_r():
    CB<u8> {
        let v = 0; // Ignore values in key-value pairs by setting to 0
        let cb = empty<u8>(); // Initialize empty tree
        // Append nodes per above tree, including bogus outer node at
        // vector index 2, which will be swap removed
        v_pu_b<I>(&mut cb.i, I{c: 2, p: ROOT, l: o_c(0), r:     1 });
        v_pu_b<I>(&mut cb.i, I{c: 1, p:    0, l: o_c(1), r: o_c(3)});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"001"), v, p: 0});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"101"), v, p: 1});
        v_pu_b<O<u8>>(&mut cb.o, O{k:    HI_128, v, p: HI_64}); // Bogus
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"111"), v, p: 1});
        // Swap remove and destruct bogus node
        let O{k: _, v: _, p: _} = v_s_r<O<u8>>(&mut cb.o, 2);
        // Stitch broken relationship
        stitch_swap_remove(&mut cb, o_c(2), 4);
        // Assert parent to relocated node indicates proper child update
        assert!(v_b<I>(&cb.i, 1).r == o_c(2), 0);
        cb // Return rather than unpack
    }

    #[test]
    /// Verify successful stitch for relocated right child inner node.
    /// `o_i` indicates outer index, `i_i` indicates inner index:
    /// ```
    /// >                2nd <- i_i = 0
    /// >               /   \
    /// >  o_i = 0 -> 001   1st <- i_i = 2 (relocated)
    /// >                  /   \
    /// >     o_i = 1 -> 101   111 <- o_i = 2
    /// ```
    fun stitch_swap_remove_i_r():
    CB<u8> {
        let v = 0; // Ignore values in key-value pairs by setting to 0
        let cb = empty<u8>(); // Initialize empty tree
        // Append nodes per above tree, including bogus inner node at
        // vector index 1, which will be swap removed
        v_pu_b<I>(&mut cb.i, I{c: 2, p: ROOT, l: o_c(0), r:     2 });
        // Bogus node
        v_pu_b<I>(&mut cb.i, I{c: 0, p:    0, l:     0 , r:     0 });
        v_pu_b<I>(&mut cb.i, I{c: 1, p:    0, l: o_c(1), r: o_c(2)});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"001"), v, p: 0});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"101"), v, p: 2});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"111"), v, p: 2});
        // Swap remove and destruct bogus node
        let I{c: _, p: _, l: _, r: _} = v_s_r<I>(&mut cb.i, 1);
        // Stitch broken relationships
        stitch_swap_remove(&mut cb, 1, 3);
        // Assert parent to relocated node indicates proper child update
        assert!(v_b<I>(&cb.i, 0).r == 1, 0);
        // Assert children to relocated node indicate proper parent
        // update
        assert!(v_b<O<u8>>(&cb.o, 1).p == 1, 1); // Left child
        assert!(v_b<O<u8>>(&cb.o, 2).p == 1, 2); // Right child
        cb // Return rather than unpack
    }

    #[test]
    /// Verify successful stitch for relocated left child inner node.
    /// `o_i` indicates outer index, `i_i` indicates inner index:
    /// ```
    /// >                 i_i = 0 -> 2nd
    /// >                           /   \
    /// >  (relocated) i_i = 2 -> 1st    100 <- i_i = 0
    /// >                        /   \
    /// >           o_i = 1 -> 001   011 <- o_i = 2
    /// ```
    fun stitch_swap_remove_i_l():
    CB<u8> {
        let v = 0; // Ignore values in key-value pairs by setting to 0
        let cb = empty<u8>(); // Initialize empty tree
        // Append nodes per above tree, including bogus inner node at
        // vector index 1, which will be swap removed
        v_pu_b<I>(&mut cb.i, I{c: 2, p: ROOT, l:     2 , r: o_c(0)});
        // Bogus node
        v_pu_b<I>(&mut cb.i, I{c: 0, p:    0, l:     0 , r:     0 });
        v_pu_b<I>(&mut cb.i, I{c: 1, p:    0, l: o_c(1), r: o_c(2)});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"100"), v, p: 0});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"001"), v, p: 2});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"011"), v, p: 2});
        // Swap remove and destruct bogus node
        let I{c: _, p: _, l: _, r: _} = v_s_r<I>(&mut cb.i, 1);
        // Stitch broken relationships
        stitch_swap_remove(&mut cb, 1, 3);
        // Assert parent to relocated node indicates proper child update
        assert!(v_b<I>(&cb.i, 0).l == 1, 0);
        // Assert children to relocated node indicate proper parent
        // update
        assert!(v_b<O<u8>>(&cb.o, 1).p == 1, 1); // Left child
        assert!(v_b<O<u8>>(&cb.o, 2).p == 1, 2); // Right child
        cb // Return rather than unpack
    }

    #[test]
    /// Verify successful stitch for relocated root inner node. `o_i`
    /// indicates outer index, `i_i` indicates inner index:
    /// ```
    /// >                2nd <- i_i = 2 (relocated)
    /// >               /   \
    /// >  o_i = 0 -> 001   1st <- i_i = 0
    /// >                  /   \
    /// >     o_i = 1 -> 101   111 <- o_i = 2
    /// ```
    fun stitch_swap_remove_r():
    CB<u8> {
        let v = 0; // Ignore values in key-value pairs by setting to 0
        let cb = empty<u8>(); // Initialize empty tree
        // Append nodes per above tree, including bogus inner node at
        // vector index 1, which will be swap removed
        v_pu_b<I>(&mut cb.i, I{c: 1, p:    2, l: o_c(1), r: o_c(2)});
        // Bogus node
        v_pu_b<I>(&mut cb.i, I{c: 0, p:    0, l:     0 , r:     0 });
        v_pu_b<I>(&mut cb.i, I{c: 2, p: ROOT, l: o_c(0), r:     0 });
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"001"), v, p: 0});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"101"), v, p: 2});
        v_pu_b<O<u8>>(&mut cb.o, O{k: u(b"111"), v, p: 2});
        // Swap remove and destruct bogus node
        let I{c: _, p: _, l: _, r: _} = v_s_r<I>(&mut cb.i, 1);
        // Stitch broken relationships
        stitch_swap_remove(&mut cb, 1, 3);
        // Assert root field reflects relocated node position
        assert!(cb.r == 1, 0);
        // Assert children to relocated node indicate proper parent
        // update
        assert!(v_b<O<u8>>(&cb.o, 0).p == 1, 1); // Left child
        assert!(v_b<I>(&cb.i, 0).p == 1, 2); // Right child
        cb // Return rather than unpack
    }

    #[test]
    /// Verify successful pop for popping left outer node:
    /// ```
    /// >        2nd (root)    Pop 1011       1100 (root)
    /// >       /   \          ------->
    /// >   1011     1100
    /// ```
    fun pop_height_one_success_l():
    CB<u8> {
        let cb = singleton(u(b"1011"), 2); // Initialize singleton
        insert(&mut cb, u(b"1100"), 5); // Insert another key
        // Assert correct pop value
        assert!(pop_height_one(&mut cb, u(b"1011")) == 2, 0);
        // Assert root index field updated correctly
        assert!(cb.r == OUT << N_TYPE, 1);
        let o_k = v_b<O<u8>>(&cb.o, 0); // Borrow kept outer node
        // Assert kept outer node fields as expected
        assert!(o_k.p == ROOT && o_k.k == u(b"1100") && o_k.v == 5, 2);
        cb // Return rather than unpack
    }

    #[test]
    /// Verify successful pop for popping right outer node:
    /// ```
    /// >        1st (root)    Pop 1110       1101 (root)
    /// >       /   \          ------->
    /// >   1101     1110
    /// ```
    fun pop_height_one_success_r():
    CB<u8> {
        let cb = singleton(u(b"1101"), 3); // Initialize singleton
        insert(&mut cb, u(b"1110"), 6); // Insert another key
        // Assert correct pop value
        assert!(pop_height_one(&mut cb, u(b"1110")) == 6, 0);
        // Assert root index field updated correctly
        assert!(cb.r == OUT << N_TYPE, 1);
        let o_k = v_b<O<u8>>(&cb.o, 0); // Borrow kept outer node
        // Assert kept outer node fields as expected
        assert!(o_k.p == ROOT && o_k.k == u(b"1101") && o_k.v == 3, 2);
        cb // Return rather than unpack
    }

    #[test]
    #[expected_failure(abort_code = 4)]
    /// Verify failure for attempting to pop value not in tree
    fun pop_height_one_failure():
    CB<u8> {
        let cb = singleton(1, 3); // Initialize singleton
        insert(&mut cb, 2, 6); // Insert another key
        let _ = pop_height_one(&mut cb, 5); // Attempt invalid pop
        cb // Return rather than unpack (or signal to compiler as much)
    }

// Popping <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

}