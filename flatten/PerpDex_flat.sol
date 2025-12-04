// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0 ^0.8.20;

// lib/openzeppelin-contracts/contracts/utils/Context.sol

// OpenZeppelin Contracts v4.4.1 (utils/Context.sol)

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

// lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol

// OpenZeppelin Contracts (last updated v4.9.0) (token/ERC20/IERC20.sol)

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `from` to `to` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// lib/pyth-sdk-solidity/IPythEvents.sol

/// @title IPythEvents contains the events that Pyth contract emits.
/// @dev This interface can be used for listening to the updates for off-chain and testing purposes.
interface IPythEvents {
    /// @dev Emitted when the price feed with `id` has received a fresh update.
    /// @param id The Pyth Price Feed ID.
    /// @param publishTime Publish time of the given price update.
    /// @param price Price of the given price update.
    /// @param conf Confidence interval of the given price update.
    event PriceFeedUpdate(
        bytes32 indexed id,
        uint64 publishTime,
        int64 price,
        uint64 conf
    );

    /// @dev Emitted when a batch price update is processed successfully.
    /// @param chainId ID of the source chain that the batch price update comes from.
    /// @param sequenceNumber Sequence number of the batch price update.
    event BatchPriceFeedUpdate(uint16 chainId, uint64 sequenceNumber);
}

// lib/pyth-sdk-solidity/PythStructs.sol

contract PythStructs {
    // A price with a degree of uncertainty, represented as a price +- a confidence interval.
    //
    // The confidence interval roughly corresponds to the standard error of a normal distribution.
    // Both the price and confidence are stored in a fixed-point numeric representation,
    // `x * (10^expo)`, where `expo` is the exponent.
    //
    // Please refer to the documentation at https://docs.pyth.network/consumers/best-practices for how
    // to how this price safely.
    struct Price {
        // Price
        int64 price;
        // Confidence interval around the price
        uint64 conf;
        // Price exponent
        int32 expo;
        // Unix timestamp describing when the price was published
        uint publishTime;
    }

    // PriceFeed represents a current aggregate price from pyth publisher feeds.
    struct PriceFeed {
        // The price ID.
        bytes32 id;
        // Latest available price
        Price price;
        // Latest available exponentially-weighted moving average price
        Price emaPrice;
    }
}

// lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol

// OpenZeppelin Contracts v4.4.1 (token/ERC20/extensions/IERC20Metadata.sol)

/**
 * @dev Interface for the optional metadata functions from the ERC20 standard.
 *
 * _Available since v4.1._
 */
interface IERC20Metadata is IERC20 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

// lib/pyth-sdk-solidity/IPyth.sol

/// @title Consume prices from the Pyth Network (https://pyth.network/).
/// @dev Please refer to the guidance at https://docs.pyth.network/consumers/best-practices for how to consume prices safely.
/// @author Pyth Data Association
interface IPyth is IPythEvents {
    /// @notice Returns the period (in seconds) that a price feed is considered valid since its publish time
    function getValidTimePeriod() external view returns (uint validTimePeriod);

    /// @notice Returns the price and confidence interval.
    /// @dev Reverts if the price has not been updated within the last `getValidTimePeriod()` seconds.
    /// @param id The Pyth Price Feed ID of which to fetch the price and confidence interval.
    /// @return price - please read the documentation of PythStructs.Price to understand how to use this safely.
    function getPrice(
        bytes32 id
    ) external view returns (PythStructs.Price memory price);

    /// @notice Returns the exponentially-weighted moving average price and confidence interval.
    /// @dev Reverts if the EMA price is not available.
    /// @param id The Pyth Price Feed ID of which to fetch the EMA price and confidence interval.
    /// @return price - please read the documentation of PythStructs.Price to understand how to use this safely.
    function getEmaPrice(
        bytes32 id
    ) external view returns (PythStructs.Price memory price);

    /// @notice Returns the price of a price feed without any sanity checks.
    /// @dev This function returns the most recent price update in this contract without any recency checks.
    /// This function is unsafe as the returned price update may be arbitrarily far in the past.
    ///
    /// Users of this function should check the `publishTime` in the price to ensure that the returned price is
    /// sufficiently recent for their application. If you are considering using this function, it may be
    /// safer / easier to use either `getPrice` or `getPriceNoOlderThan`.
    /// @return price - please read the documentation of PythStructs.Price to understand how to use this safely.
    function getPriceUnsafe(
        bytes32 id
    ) external view returns (PythStructs.Price memory price);

    /// @notice Returns the price that is no older than `age` seconds of the current time.
    /// @dev This function is a sanity-checked version of `getPriceUnsafe` which is useful in
    /// applications that require a sufficiently-recent price. Reverts if the price wasn't updated sufficiently
    /// recently.
    /// @return price - please read the documentation of PythStructs.Price to understand how to use this safely.
    function getPriceNoOlderThan(
        bytes32 id,
        uint age
    ) external view returns (PythStructs.Price memory price);

    /// @notice Returns the exponentially-weighted moving average price of a price feed without any sanity checks.
    /// @dev This function returns the same price as `getEmaPrice` in the case where the price is available.
    /// However, if the price is not recent this function returns the latest available price.
    ///
    /// The returned price can be from arbitrarily far in the past; this function makes no guarantees that
    /// the returned price is recent or useful for any particular application.
    ///
    /// Users of this function should check the `publishTime` in the price to ensure that the returned price is
    /// sufficiently recent for their application. If you are considering using this function, it may be
    /// safer / easier to use either `getEmaPrice` or `getEmaPriceNoOlderThan`.
    /// @return price - please read the documentation of PythStructs.Price to understand how to use this safely.
    function getEmaPriceUnsafe(
        bytes32 id
    ) external view returns (PythStructs.Price memory price);

    /// @notice Returns the exponentially-weighted moving average price that is no older than `age` seconds
    /// of the current time.
    /// @dev This function is a sanity-checked version of `getEmaPriceUnsafe` which is useful in
    /// applications that require a sufficiently-recent price. Reverts if the price wasn't updated sufficiently
    /// recently.
    /// @return price - please read the documentation of PythStructs.Price to understand how to use this safely.
    function getEmaPriceNoOlderThan(
        bytes32 id,
        uint age
    ) external view returns (PythStructs.Price memory price);

    /// @notice Update price feeds with given update messages.
    /// This method requires the caller to pay a fee in wei; the required fee can be computed by calling
    /// `getUpdateFee` with the length of the `updateData` array.
    /// Prices will be updated if they are more recent than the current stored prices.
    /// The call will succeed even if the update is not the most recent.
    /// @dev Reverts if the transferred fee is not sufficient or the updateData is invalid.
    /// @param updateData Array of price update data.
    function updatePriceFeeds(bytes[] calldata updateData) external payable;

    /// @notice Wrapper around updatePriceFeeds that rejects fast if a price update is not necessary. A price update is
    /// necessary if the current on-chain publishTime is older than the given publishTime. It relies solely on the
    /// given `publishTimes` for the price feeds and does not read the actual price update publish time within `updateData`.
    ///
    /// This method requires the caller to pay a fee in wei; the required fee can be computed by calling
    /// `getUpdateFee` with the length of the `updateData` array.
    ///
    /// `priceIds` and `publishTimes` are two arrays with the same size that correspond to senders known publishTime
    /// of each priceId when calling this method. If all of price feeds within `priceIds` have updated and have
    /// a newer or equal publish time than the given publish time, it will reject the transaction to save gas.
    /// Otherwise, it calls updatePriceFeeds method to update the prices.
    ///
    /// @dev Reverts if update is not needed or the transferred fee is not sufficient or the updateData is invalid.
    /// @param updateData Array of price update data.
    /// @param priceIds Array of price ids.
    /// @param publishTimes Array of publishTimes. `publishTimes[i]` corresponds to known `publishTime` of `priceIds[i]`
    function updatePriceFeedsIfNecessary(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64[] calldata publishTimes
    ) external payable;

    /// @notice Returns the required fee to update an array of price updates.
    /// @param updateData Array of price update data.
    /// @return feeAmount The required fee in Wei.
    function getUpdateFee(
        bytes[] calldata updateData
    ) external view returns (uint feeAmount);

    /// @notice Parse `updateData` and return price feeds of the given `priceIds` if they are all published
    /// within `minPublishTime` and `maxPublishTime`.
    ///
    /// You can use this method if you want to use a Pyth price at a fixed time and not the most recent price;
    /// otherwise, please consider using `updatePriceFeeds`. This method does not store the price updates on-chain.
    ///
    /// This method requires the caller to pay a fee in wei; the required fee can be computed by calling
    /// `getUpdateFee` with the length of the `updateData` array.
    ///
    ///
    /// @dev Reverts if the transferred fee is not sufficient or the updateData is invalid or there is
    /// no update for any of the given `priceIds` within the given time range.
    /// @param updateData Array of price update data.
    /// @param priceIds Array of price ids.
    /// @param minPublishTime minimum acceptable publishTime for the given `priceIds`.
    /// @param maxPublishTime maximum acceptable publishTime for the given `priceIds`.
    /// @return priceFeeds Array of the price feeds corresponding to the given `priceIds` (with the same order).
    function parsePriceFeedUpdates(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PythStructs.PriceFeed[] memory priceFeeds);
}

// lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol

// OpenZeppelin Contracts (last updated v4.9.0) (token/ERC20/ERC20.sol)

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 * For a generic mechanism see {ERC20PresetMinterPauser}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.openzeppelin.com/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * The default value of {decimals} is 18. To change this, you should override
 * this function so it returns a different value.
 *
 * We have followed general OpenZeppelin Contracts guidelines: functions revert
 * instead returning `false` on failure. This behavior is nonetheless
 * conventional and does not conflict with the expectations of ERC20
 * applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 *
 * Finally, the non-standard {decreaseAllowance} and {increaseAllowance}
 * functions have been added to mitigate the well-known issues around setting
 * allowances. See {IERC20-approve}.
 */
contract ERC20 is Context, IERC20, IERC20Metadata {
    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the default value returned by this function, unless
     * it's overridden.
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `amount` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `from` must have a balance of at least `amount`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `amount`.
     */
    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, allowance(owner, spender) + addedValue);
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        address owner = _msgSender();
        uint256 currentAllowance = allowance(owner, spender);
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    /**
     * @dev Moves `amount` of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `from` must have a balance of at least `amount`.
     */
    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(from, to, amount);

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
            // Overflow not possible: the sum of all balances is capped by totalSupply, and the sum is preserved by
            // decrementing then incrementing.
            _balances[to] += amount;
        }

        emit Transfer(from, to, amount);

        _afterTokenTransfer(from, to, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        unchecked {
            // Overflow not possible: balance + amount is at most totalSupply + amount, which is checked above.
            _balances[account] += amount;
        }
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
            // Overflow not possible: amount <= accountBalance <= totalSupply.
            _totalSupply -= amount;
        }

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `amount`.
     *
     * Does not update the allowance amount in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Might emit an {Approval} event.
     */
    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual {}

    /**
     * @dev Hook that is called after any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * has been transferred to `to`.
     * - when `from` is zero, `amount` tokens have been minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens have been burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual {}
}

// src/PerpDex.sol

contract PerpDEX {
    IPyth public immutable pyth;
    ERC20 public immutable usdt;

    // ---------- Ownership ----------
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not admin");
        _;
    }

    // ---------- Fixed-point base ----------
    uint256 public constant ONE = 1e18;

    // ---------- Economic Params ----------
    uint256 public constant FEE_RATIO = 0; // 0% open/close fee (for now)
    uint256 public constant SPREAD_BPS = 0; // 0 bps spread (for now)
    uint256 public constant MAINTENANCE_MARGIN_RATIO = 0; // 0% =>  
    uint256 public constant LIQUIDATION_REWARD_RATIO = 2e16; // 2% (currently unused)

    uint256 public constant MAX_DAILY_FUNDING_BPS = 100; // 1% per day max
    uint256 public constant FUNDING_MAX_PER_SEC =
        ((ONE * MAX_DAILY_FUNDING_BPS) / 10000) / 86400;

    // 🔥 Max PnL = 500% of margin (so profit <= 5x margin)
    uint256 public constant MAX_PNL_RATIO = 5e18; // 500% expressed in 1e18 fixed-point

    // ---------- Data Models ----------
    struct Position {
        bytes32 id;
        string pairs;
        bool isLong;
        uint256 margin; // netMargin (after open fee)
        uint256 leverage;
        uint256 size; // position notional
        uint256 entryPrice;
        bytes32 pythTokenId;
        bool isClosed;
        uint256 closePrice;
        uint256 payout;
        uint256 liquidationPrice;
        uint256 fees; // open fee
        int256 fundingEntry;
        uint256 takeProfit; // 0 = none
        uint256 stopLoss; // 0 = none
    }

    struct PairFunding {
        uint256 oiLong;
        uint256 oiShort;
        int256 growth;
        uint256 lastUpdate;
    }

    struct PairInfo {
        string name;
        bytes32 pythTokenId;
        bool active;
    }

    // ---------- Storage ----------
    mapping(address => Position[]) public positions;
    mapping(address => string) public username;
    mapping(string => PairFunding) public pairFunding;
    mapping(string => PairInfo) public pairInfo;

    PairInfo[] public allPairs;
    address[] public allUsers;

    // ---------- LP Pool ----------
    uint256 public totalLpShares;
    mapping(address => uint256) public lpShares;

    // Sum of margin locked in open positions (netMargin only)
    uint256 public totalOpenMargin;

    // ---------- Events ----------
    event OpenPosition(
        bytes32 indexed id,
        address indexed user,
        string pairs,
        bool isLong,
        uint256 margin,
        uint256 leverage,
        uint256 size,
        uint256 entryPrice,
        bytes32 pythTokenId,
        uint256 liquidationPrice,
        uint256 fees
    );
    event ClosePosition(
        bytes32 indexed id,
        address indexed user,
        uint256 closePrice,
        uint256 payout,
        uint256 closeFee
    );
    event RegisterUser(address indexed userAddress, string username);
    event FundingUpdated(
        string pairs,
        int256 newGrowth,
        uint256 oiLong,
        uint256 oiShort,
        uint256 timestamp
    );
    event PairAdded(string name, bytes32 pythTokenId);
    event PairStatus(string name, bool active);
    event OwnershipTransferred(
        address indexed oldOwner,
        address indexed newOwner
    );
    event AllPositionsClosed(address indexed admin, uint256 timestamp);

    // LP events
    event LPDeposit(address indexed user, uint256 amount, uint256 shares);
    event LPWithdraw(address indexed user, uint256 amount, uint256 shares);

    // ---------- Constructor ----------
    constructor(address _usdt, address _pyth) {
        require(_usdt != address(0) && _pyth != address(0), "Invalid address");
        usdt = ERC20(_usdt);
        pyth = IPyth(_pyth);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        _addInitialPairs();
    }

    // ---------- Receive Native Token ----------
    receive() external payable {}

    // ---------- Initial Pairs ----------
    function _addInitialPairs() internal {
        addPairInternal(
            "BTC_USD",
            0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
        );
        addPairInternal(
            "ETH_USD",
            0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace
        );
        addPairInternal(
            "SOL_USD",
            0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d
        );
        addPairInternal(
            "BNB_USD",
            0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f
        );
        addPairInternal(
            "XRP_USD",
            0xec5d399846a9209f3fe5881d70aae9268c94339ff9817e8d18ff19fa05eea1c8
        );
        addPairInternal(
            "DOGE_USD",
            0xdcef50dd0a4cd2dcc17e45df1676dcb336a11a61c69df7a0299b0150c672d25c
        );
        addPairInternal(
            "HYPE_USD",
            0x4279e31cc369bbcc2faf022b382b080e32a8e689ff20fbc530d2a603eb6cd98b
        );
        addPairInternal(
            "SUI_USD",
            0x23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744
        );
        addPairInternal(
            "OP_USD",
            0x385f64d993f7b77d8182ed5003d97c60aa3361f3cecfe711544d2d59165e9bdf
        );
        addPairInternal(
            "ARB_USD",
            0x3fa4252848f9f0a1480be62745a4629d9eb1322aebab8a791e344b3b9c1adcf5
        );
    }

    function addPairInternal(
        string memory pairs,
        bytes32 pythTokenId
    ) internal {
        pairInfo[pairs] = PairInfo({
            name: pairs,
            pythTokenId: pythTokenId,
            active: true
        });
        allPairs.push(pairInfo[pairs]);
        emit PairAdded(pairs, pythTokenId);
        emit PairStatus(pairs, true);
    }

    // ---------- Admin Pair Management ----------
    function addPairBatch(
        string[] calldata names,
        bytes32[] calldata pythTokenIds
    ) external onlyOwner {
        require(names.length == pythTokenIds.length, "Length mismatch");
        for (uint256 i = 0; i < names.length; i++) {
            require(!pairInfo[names[i]].active, "Pair exists");
            pairInfo[names[i]] = PairInfo({
                name: names[i],
                pythTokenId: pythTokenIds[i],
                active: true
            });
            allPairs.push(pairInfo[names[i]]);
            emit PairAdded(names[i], pythTokenIds[i]);
            emit PairStatus(names[i], true);
        }
    }

    function addPair(
        string calldata pairs,
        bytes32 pythTokenId
    ) external onlyOwner {
        require(!pairInfo[pairs].active, "Pair exists");
        pairInfo[pairs] = PairInfo({
            name: pairs,
            pythTokenId: pythTokenId,
            active: true
        });
        allPairs.push(pairInfo[pairs]);
        emit PairAdded(pairs, pythTokenId);
        emit PairStatus(pairs, true);
    }

    function setPairActive(
        string calldata pairs,
        bool active
    ) external onlyOwner {
        require(bytes(pairInfo[pairs].name).length > 0, "Pair unknown");
        pairInfo[pairs].active = active;
        emit PairStatus(pairs, active);
    }

    function getAllPairs() external view returns (PairInfo[] memory) {
        return allPairs;
    }

    // ---------- Ownership ----------
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Bad owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ---------- Users ----------
    function registerUser(string calldata _username) external {
        require(bytes(_username).length > 0, "Empty username");
        if (bytes(username[msg.sender]).length == 0) {
            allUsers.push(msg.sender);
        }
        username[msg.sender] = _username;
        emit RegisterUser(msg.sender, _username);
    }

    function editUsername(string calldata _username) external {
        require(bytes(_username).length > 0, "Empty username");
        require(bytes(username[msg.sender]).length > 0, "Not registered");
        username[msg.sender] = _username;
        emit RegisterUser(msg.sender, _username);
    }

    // ===============================================================
    // LP POOL LOGIC
    // ===============================================================

    /// @dev LP equity = USDT balance - totalOpenMargin
    function getPoolValue() public view returns (uint256) {
        uint256 bal = usdt.balanceOf(address(this));
        if (bal > totalOpenMargin) {
            return bal - totalOpenMargin;
        }
        return 0;
    }

    function getSharePrice() external view returns (uint256) {
        if (totalLpShares == 0) return ONE;
        uint256 pool = getPoolValue();
        return (pool * ONE) / totalLpShares;
    }

    /// @notice Deposit USDT to the LP pool and receive LP shares
    function depositLP(uint256 amount) external {
        require(amount > 0, "amount=0");

        uint256 poolBefore = getPoolValue();
        uint256 shares;

        if (totalLpShares == 0 || poolBefore == 0) {
            // initial: 1:1
            shares = amount;
        } else {
            shares = (amount * totalLpShares) / poolBefore;
        }

        require(shares > 0, "shares=0");

        require(
            usdt.transferFrom(msg.sender, address(this), amount),
            "USDT transfer failed"
        );

        lpShares[msg.sender] += shares;
        totalLpShares += shares;

        emit LPDeposit(msg.sender, amount, shares);
    }

    /// @notice Withdraw USDT by burning LP shares
    function withdrawLP(uint256 shares) external {
        require(shares > 0, "shares=0");
        uint256 userShares = lpShares[msg.sender];
        require(userShares >= shares, "insufficient shares");

        uint256 pool = getPoolValue();
        require(pool > 0 && totalLpShares > 0, "empty pool");

        uint256 amount = (shares * pool) / totalLpShares;
        require(amount > 0, "amount=0");

        lpShares[msg.sender] = userShares - shares;
        totalLpShares -= shares;

        require(usdt.transfer(msg.sender, amount), "USDT transfer failed");
        emit LPWithdraw(msg.sender, amount, shares);
    }

    // ===============================================================
    // FUNDING
    // ===============================================================

    function updateFunding(string calldata pairs) public {
        _accrueFunding(pairs);
        PairFunding storage pf = pairFunding[pairs];
        emit FundingUpdated(
            pairs,
            pf.growth,
            pf.oiLong,
            pf.oiShort,
            block.timestamp
        );
    }

    function _accrueFunding(string memory pairs) internal {
        PairFunding storage pf = pairFunding[pairs];
        uint256 last = pf.lastUpdate;
        if (last == 0) {
            pf.lastUpdate = block.timestamp;
            return;
        }

        uint256 dt = block.timestamp - last;
        if (dt == 0) return;

        uint256 longOI = pf.oiLong;
        uint256 shortOI = pf.oiShort;
        uint256 totalOI = longOI + shortOI;
        if (totalOI == 0) {
            pf.lastUpdate = block.timestamp;
            return;
        }

        uint256 diff = longOI > shortOI ? longOI - shortOI : shortOI - longOI;
        uint256 imbalanceRatio = (diff * ONE) / totalOI;
        uint256 magPerSec = (FUNDING_MAX_PER_SEC * imbalanceRatio) / ONE;
        int256 signedPerSec = longOI >= shortOI
            ? int256(magPerSec)
            : -int256(magPerSec);

        pf.growth += signedPerSec * int256(dt);
        pf.lastUpdate = block.timestamp;
    }

    // ===============================================================
    // PYTH HELPERS (PULL ORACLE)
    // ===============================================================

    /// @dev Updates Pyth price feeds with fresh updateData (Hermes)
    ///      and returns the current Price struct for the given priceId.
    function _updateAndGetPythPrice(
        bytes[] calldata priceUpdateData,
        bytes32 priceId
    ) internal returns (PythStructs.Price memory) {
        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        require(msg.value >= fee, "Insufficient Pyth fee");
        pyth.updatePriceFeeds{value: fee}(priceUpdateData);

        // Now get the (fresh) price
        PythStructs.Price memory p = pyth.getPrice(priceId);
        require(p.price > 0, "Invalid Pyth price");
        return p;
    }

    // ===============================================================
    // OPEN POSITION (uses Pyth pull oracle)
    // ===============================================================

    function openPosition(
        string calldata pairs,
        bool isLong,
        uint256 margin,
        uint256 leverage,
        bytes[] calldata priceUpdateData,
        uint256 takeProfit, // 0 = none
        uint256 stopLoss // 0 = none
    ) external payable {
        require(margin > 0 && leverage > 0, "Bad margin/leverage");

        PairInfo storage info = pairInfo[pairs];
        require(info.active, "Pair not supported");

        // 1) Update Pyth and get fresh price for this pair
        PythStructs.Price memory token = _updateAndGetPythPrice(
            priceUpdateData,
            info.pythTokenId
        );
        uint256 oraclePrice = toUint(token.price);

        // 2) Pull margin from trader
        require(
            usdt.transferFrom(msg.sender, address(this), margin),
            "USDT pull failed"
        );

        // 3) Fee + net margin
        uint256 fees = (margin * leverage * FEE_RATIO) / ONE;
        uint256 netMargin = margin - fees;
        uint256 netSize = netMargin * leverage;

        // 4) Track locked margin for pool-equity calculations
        totalOpenMargin += netMargin;

        _finalizeOpenPosition(
            pairs,
            isLong,
            netMargin,
            leverage,
            netSize,
            info.pythTokenId,
            fees,
            oraclePrice,
            takeProfit,
            stopLoss
        );
    }

    function _finalizeOpenPosition(
        string calldata pairs,
        bool isLong,
        uint256 netMargin,
        uint256 leverage,
        uint256 netSize,
        bytes32 pythTokenId,
        uint256 fees,
        uint256 signedPrice,
        uint256 tp,
        uint256 sl
    ) internal {
        _accrueFunding(pairs);

        uint256 entryPrice = applySpread(signedPrice, isLong, true);

        uint256 liquidationPrice = calculateLiquidationPrice(
            entryPrice,
            netSize,
            netMargin,
            isLong
        );

        bytes32 id = keccak256(
            abi.encodePacked(msg.sender, block.timestamp, block.number)
        );
        PairFunding storage pf = pairFunding[pairs];

        positions[msg.sender].push(
            Position({
                id: id,
                pairs: pairs,
                isLong: isLong,
                margin: netMargin,
                leverage: leverage,
                size: netSize,
                entryPrice: entryPrice,
                pythTokenId: pythTokenId,
                isClosed: false,
                closePrice: 0,
                payout: 0,
                liquidationPrice: liquidationPrice,
                fees: fees,
                fundingEntry: pf.growth,
                takeProfit: tp,
                stopLoss: sl
            })
        );

        if (isLong) pf.oiLong += netSize;
        else pf.oiShort += netSize;

        emit OpenPosition(
            id,
            msg.sender,
            pairs,
            isLong,
            netMargin,
            leverage,
            netSize,
            entryPrice,
            pythTokenId,
            liquidationPrice,
            fees
        );
    }

    // ===============================================================
    // MODIFY TP / SL
    // ===============================================================

    function modifyTpSl(
        bytes32 positionId,
        uint256 newTP,
        uint256 newSL
    ) external {
        Position[] storage userPositions = positions[msg.sender];

        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];

            if (pos.id == positionId && !pos.isClosed) {
                if (newTP > 0) {
                    pos.takeProfit = newTP;
                } else {
                    pos.takeProfit = 0;
                }

                if (newSL > 0) {
                    pos.stopLoss = newSL;
                } else {
                    pos.stopLoss = 0;
                }

                return;
            }
        }

        revert("Position not found");
    }

    // ===============================================================
    // CLOSE POSITION (manual close using fresh Pyth price)
    // ===============================================================

    function closePosition(
        bytes32 positionId,
        bytes[] calldata priceUpdateData
    ) external payable {
        Position[] storage userPositions = positions[msg.sender];
        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];
            if (!pos.isClosed && pos.id == positionId) {
                // Fetch fresh price from Pyth for manual close
                PythStructs.Price memory token = _updateAndGetPythPrice(
                    priceUpdateData,
                    pos.pythTokenId
                );
                uint256 currentPrice = toUint(token.price); // no spread on close

                _closePosition(msg.sender, pos, currentPrice);
                return;
            }
        }
        revert("Position not found/already closed");
    }

    // ===============================================================
    // TP/SL TRIGGER (bot) - close at Pyth TP/SL price
    // ===============================================================

    function triggerTpSl(
        address user,
        bytes32 positionId,
        bytes[] calldata priceUpdateData
    ) external payable {
        Position[] storage userPositions = positions[user];

        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];

            if (pos.id == positionId && !pos.isClosed) {
                // Fresh Pyth price
                PythStructs.Price memory token = _updateAndGetPythPrice(
                    priceUpdateData,
                    pos.pythTokenId
                );
                uint256 oraclePrice = toUint(token.price);

                bool hitTP = false;
                bool hitSL = false;

                // Long: TP if price >= TP, SL if price <= SL
                // Short: TP if price <= TP, SL if price >= SL
                if (pos.takeProfit > 0) {
                    if (pos.isLong && oraclePrice >= pos.takeProfit)
                        hitTP = true;
                    if (!pos.isLong && oraclePrice <= pos.takeProfit)
                        hitTP = true;
                }

                if (pos.stopLoss > 0) {
                    if (pos.isLong && oraclePrice <= pos.stopLoss) hitSL = true;
                    if (!pos.isLong && oraclePrice >= pos.stopLoss)
                        hitSL = true;
                }

                require(hitTP || hitSL, "No TP/SL triggered");

                // Close using oraclePrice (exact TP/SL execution)
                _closePosition(user, pos, oraclePrice);

                return;
            }
        }

        revert("Position not found");
    }

    // ===============================================================
    // LIQUIDATION (bot)
    // ===============================================================

    function liquidate(
        address user,
        bytes32 positionId,
        bytes[] calldata priceUpdateData
    ) external payable {
        Position[] storage userPositions = positions[user];

        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];

            if (pos.id == positionId && !pos.isClosed) {
                // --- 1) Get fresh price from Pyth ---
                PythStructs.Price memory token = _updateAndGetPythPrice(
                    priceUpdateData,
                    pos.pythTokenId
                );
                uint256 oraclePrice = toUint(token.price);

                // --- 2) Compute PnL ---
                int256 pnl = pos.isLong
                    ? (int256(pos.size) *
                        (int256(oraclePrice) - int256(pos.entryPrice))) /
                        int256(pos.entryPrice)
                    : (int256(pos.size) *
                        (int256(pos.entryPrice) - int256(oraclePrice))) /
                        int256(pos.entryPrice);

                PairFunding storage pf = pairFunding[pos.pairs];
                int256 fundingPayment = (int256(pos.size) *
                    (pf.growth - pos.fundingEntry)) / int256(ONE);

                int256 equity = int256(pos.margin) + pnl - fundingPayment;

                // --- 3) Check liquidation condition ---
                // MAINTENANCE_MARGIN = 0 → equity must be <= 0
                require(equity <= 0, "Position not liquidatable");

                // --- 4) Reduce OI ---
                if (pos.isLong) {
                    pf.oiLong = pf.oiLong >= pos.size
                        ? pf.oiLong - pos.size
                        : 0;
                } else {
                    pf.oiShort = pf.oiShort >= pos.size
                        ? pf.oiShort - pos.size
                        : 0;
                }

                // --- 5) Deduct locked margin ---
                if (totalOpenMargin >= pos.margin) {
                    totalOpenMargin -= pos.margin;
                } else {
                    totalOpenMargin = 0;
                }

                // --- 6) Liquidator reward (optional, currently disabled) ---
                // uint256 reward = (pos.margin * LIQUIDATION_REWARD_RATIO) / ONE;
                // if (reward > 0) usdt.transfer(msg.sender, reward);

                // --- 7) No payout to trader, they lost margin ---
                pos.isClosed = true;
                pos.closePrice = oraclePrice;
                pos.payout = 0;

                emit ClosePosition(
                    pos.id,
                    user,
                    oraclePrice,
                    0,
                    0 // no fee
                );

                return;
            }
        }

        revert("Position not found");
    }

    // ===============================================================
    // Internal close logic (shared by manual close & TP/SL trigger)
    // ===============================================================

    function _closePosition(
        address user,
        Position storage pos,
        uint256 currentPrice
    ) internal {
        _accrueFunding(pos.pairs);

        // Basic PnL formula
        int256 pnl = pos.isLong
            ? (int256(pos.size) *
                (int256(currentPrice) - int256(pos.entryPrice))) /
                int256(pos.entryPrice)
            : (int256(pos.size) *
                (int256(pos.entryPrice) - int256(currentPrice))) /
                int256(pos.entryPrice);

        PairFunding storage pf = pairFunding[pos.pairs];
        int256 fundingPayment = (int256(pos.size) *
            (pf.growth - pos.fundingEntry)) / int256(ONE);

        // 🔥 Cap PnL at +500% of margin
        int256 cappedPnl = pnl;
        if (cappedPnl > 0) {
            int256 maxPnl = int256((pos.margin * MAX_PNL_RATIO) / ONE); // 5x margin
            if (cappedPnl > maxPnl) {
                cappedPnl = maxPnl;
            }
        }

        int256 rawPayout = int256(pos.margin) + cappedPnl - fundingPayment;
        uint256 payout = rawPayout > 0 ? uint256(rawPayout) : 0;

        // Close fee to pool (currently 0)
        uint256 closeFee = (payout * FEE_RATIO) / ONE;
        payout = payout > closeFee ? payout - closeFee : 0;

        // Update OI
        if (pos.isLong) {
            pf.oiLong = pf.oiLong >= pos.size ? pf.oiLong - pos.size : 0;
        } else {
            pf.oiShort = pf.oiShort >= pos.size ? pf.oiShort - pos.size : 0;
        }

        // Release locked margin tracking
        if (totalOpenMargin >= pos.margin) {
            totalOpenMargin -= pos.margin;
        } else {
            totalOpenMargin = 0;
        }

        // Payout to trader comes from pool
        if (payout > 0) {
            require(usdt.transfer(user, payout), "USDT transfer failed");
        }

        pos.isClosed = true;
        pos.closePrice = currentPrice;
        pos.payout = payout;

        emit ClosePosition(pos.id, user, currentPrice, payout, closeFee);
    }

    // ===============================================================
    // Admin: Close all positions (emergency, uses whatever on-chain Pyth price)
    // ===============================================================

    function closeAllPositions() external onlyOwner {
        for (uint256 u = 0; u < allUsers.length; u++) {
            address user = allUsers[u];
            Position[] storage userPositions = positions[user];
            for (uint256 i = 0; i < userPositions.length; i++) {
                Position storage pos = userPositions[i];
                if (!pos.isClosed) {
                    PythStructs.Price memory token = pyth.getPrice(
                        pos.pythTokenId
                    );
                    if (token.price <= 0) {
                        continue;
                    }
                    uint256 currentPrice = toUint(token.price);
                    _closePosition(user, pos, currentPrice);
                }
            }
        }
        emit AllPositionsClosed(msg.sender, block.timestamp);
    }

    // ===============================================================
    // Helpers
    // ===============================================================

    function calculateLiquidationPrice(
        uint256 entryPrice,
        uint256 size,
        uint256 margin,
        bool isLong
    ) internal pure returns (uint256) {
        // With MAINTENANCE_MARGIN_RATIO = 0, this becomes bankruptcy price:
        // priceChange = entryPrice * margin / size = entryPrice / leverage
        uint256 maint = (margin * MAINTENANCE_MARGIN_RATIO) / ONE; // = 0 now
        uint256 effective = margin - maint;
        uint256 priceChange = (entryPrice * effective) / size;

        return isLong ? entryPrice - priceChange : entryPrice + priceChange;
    }

    function applySpread(
        uint256 price,
        bool isLong,
        bool isEntry
    ) internal pure returns (uint256) {
        uint256 spread = (price * SPREAD_BPS) / 10000;
        if (isEntry) {
            return isLong ? price + spread : price - spread;
        }
        return isLong ? price - spread : price + spread;
    }

    function toUint(int64 x) internal pure returns (uint256) {
        require(x >= 0, "Negative price");
        return uint256(int256(x));
    }
}

