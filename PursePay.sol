// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title PursePay
 * @author PursePay Protocol
 * @notice A seller payment platform where sellers create on-chain purses with
 *         a fixed payment address and a mutable price. The purse ID is stable
 *         forever; the price can be updated by the owner at any time without
 *         affecting the QR code (which encodes the purse ID, not the price).
 *
 * @dev Architecture:
 *   - PurseRegistry  – deploys one PurseWallet per seller via CREATE2 so the
 *                      contract address (= QR payload) never changes even after
 *                      a price update.
 *   - PurseWallet    – minimal proxy that holds the purse state and accepts ETH
 *                      or ERC-20 payments on behalf of the seller.
 *   - IPurseWallet   – interface consumed by the registry and external tooling.
 *
 * Flow:
 *   1. Seller calls PurseRegistry.createPurse(name, description, amount, token)
 *   2. Registry deploys a PurseWallet at a deterministic address (salt = purseId)
 *   3. The wallet address IS the on-chain purse ID → goes into the QR code
 *   4. Buyer scans QR, resolves current price via PurseWallet.currentPrice()
 *   5. Buyer calls PurseWallet.pay{value: price}() (ETH) or pay(amount) (ERC-20)
 *   6. Funds land in the wallet; seller withdraws via PurseWallet.withdraw()
 *   7. Seller calls PurseWallet.setPrice(newAmount) to update price; QR unchanged
 */

// ─────────────────────────────────────────────
// Dependencies (inline minimal interfaces)
// ─────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

// ─────────────────────────────────────────────
// IPurseWallet
// ─────────────────────────────────────────────

interface IPurseWallet {
    function initialize(
        address owner_,
        string calldata name_,
        string calldata description_,
        uint256 amount_,
        address token_      // address(0) = native ETH
    ) external;

    function pay() external payable;
    function payERC20(uint256 amount) external;

    function setPrice(uint256 newAmount) external;
    function setDescription(string calldata newDescription) external;
    function withdraw() external;
    function withdrawERC20(address token) external;

    function owner() external view returns (address);
    function name() external view returns (string memory);
    function description() external view returns (string memory);
    function currentPrice() external view returns (uint256);
    function token() external view returns (address);
    function totalReceived() external view returns (uint256);
    function paymentCount() external view returns (uint256);
}

// ─────────────────────────────────────────────
// PurseWallet
// ─────────────────────────────────────────────

contract PurseWallet is IPurseWallet {

    // ── State ──────────────────────────────────

    address private _owner;
    address private _token;          // address(0) = ETH
    string  private _name;
    string  private _description;
    uint256 private _price;          // in token's smallest unit (wei for ETH)
    uint256 private _totalReceived;
    uint256 private _paymentCount;
    bool    private _initialized;

    // ── Events ─────────────────────────────────

    event PaymentReceived(address indexed payer, uint256 amount, uint256 timestamp);
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);
    event DescriptionUpdated(string newDescription);
    event Withdrawn(address indexed to, uint256 amount, address token);

    // ── Errors ─────────────────────────────────

    error AlreadyInitialized();
    error NotOwner();
    error WrongPaymentAmount(uint256 sent, uint256 required);
    error ZeroPrice();
    error TransferFailed();
    error NothingToWithdraw();

    // ── Modifiers ──────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner();
        _;
    }

    modifier notInitialized() {
        if (_initialized) revert AlreadyInitialized();
        _;
    }

    // ── Init (called by registry via CREATE2) ──

    /**
     * @notice One-time initializer called immediately after deployment.
     * @param owner_       The seller who owns this purse.
     * @param name_        Human-readable purse name.
     * @param description_ Optional description of what is being sold.
     * @param amount_      Price in the token's smallest unit.
     * @param token_       ERC-20 token address; address(0) for native ETH.
     */
    function initialize(
        address owner_,
        string calldata name_,
        string calldata description_,
        uint256 amount_,
        address token_
    ) external override notInitialized {
        if (amount_ == 0) revert ZeroPrice();
        _owner       = owner_;
        _name        = name_;
        _description = description_;
        _price       = amount_;
        _token       = token_;
        _initialized = true;
    }

    // ── Payment ────────────────────────────────

    /**
     * @notice Pay in native ETH. Must send exactly currentPrice() wei.
     */
    function pay() external payable override {
        if (msg.value != _price) revert WrongPaymentAmount(msg.value, _price);
        _totalReceived += msg.value;
        _paymentCount  += 1;
        emit PaymentReceived(msg.sender, msg.value, block.timestamp);
    }

    /**
     * @notice Pay in the configured ERC-20 token.
     * @dev Caller must have approved this contract for `amount` tokens first.
     * @param amount Must equal currentPrice().
     */
    function payERC20(uint256 amount) external override {
        if (_token == address(0)) revert TransferFailed(); // ETH-only purse
        if (amount != _price) revert WrongPaymentAmount(amount, _price);
        bool ok = IERC20(_token).transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();
        _totalReceived += amount;
        _paymentCount  += 1;
        emit PaymentReceived(msg.sender, amount, block.timestamp);
    }

    // ── Owner actions ──────────────────────────

    /**
     * @notice Update the price. The purse ID (contract address) and QR code
     *         are completely unaffected — only the displayed price changes.
     * @param newAmount New price in the token's smallest unit.
     */
    function setPrice(uint256 newAmount) external override onlyOwner {
        if (newAmount == 0) revert ZeroPrice();
        emit PriceUpdated(_price, newAmount);
        _price = newAmount;
    }

    /**
     * @notice Update the description shown to buyers.
     */
    function setDescription(string calldata newDescription) external override onlyOwner {
        _description = newDescription;
        emit DescriptionUpdated(newDescription);
    }

    /**
     * @notice Withdraw all accumulated ETH to the owner.
     */
    function withdraw() external override onlyOwner {
        uint256 bal = address(this).balance;
        if (bal == 0) revert NothingToWithdraw();
        (bool sent,) = _owner.call{value: bal}("");
        if (!sent) revert TransferFailed();
        emit Withdrawn(_owner, bal, address(0));
    }

    /**
     * @notice Withdraw any ERC-20 token balance to the owner.
     *         Useful if the purse received tokens or if the configured token is ERC-20.
     * @param token_ The ERC-20 contract address to withdraw.
     */
    function withdrawERC20(address token_) external override onlyOwner {
        uint256 bal = IERC20(token_).balanceOf(address(this));
        if (bal == 0) revert NothingToWithdraw();
        bool ok = IERC20(token_).transfer(_owner, bal);
        if (!ok) revert TransferFailed();
        emit Withdrawn(_owner, bal, token_);
    }

    // ── View ───────────────────────────────────

    function owner()         external view override returns (address)  { return _owner; }
    function name()          external view override returns (string memory) { return _name; }
    function description()   external view override returns (string memory) { return _description; }
    function currentPrice()  external view override returns (uint256)  { return _price; }
    function token()         external view override returns (address)  { return _token; }
    function totalReceived() external view override returns (uint256)  { return _totalReceived; }
    function paymentCount()  external view override returns (uint256)  { return _paymentCount; }

    /// @notice Convenience: full purse snapshot in one call (saves RPC round trips)
    function info() external view returns (
        address owner_,
        string memory name_,
        string memory description_,
        uint256 price_,
        address token_,
        uint256 totalReceived_,
        uint256 paymentCount_,
        uint256 ethBalance_
    ) {
        return (
            _owner, _name, _description, _price, _token,
            _totalReceived, _paymentCount, address(this).balance
        );
    }

    /// @notice Accept ETH sent without calldata (e.g. direct transfers).
    receive() external payable {
        _totalReceived += msg.value;
        _paymentCount  += 1;
        emit PaymentReceived(msg.sender, msg.value, block.timestamp);
    }
}

// ─────────────────────────────────────────────
// PurseRegistry
// ─────────────────────────────────────────────

/**
 * @title PurseRegistry
 * @notice Factory that deploys PurseWallet contracts via CREATE2.
 *         The wallet's address is deterministic from (seller, salt) and serves
 *         as the permanent on-chain purse identifier embedded in the QR code.
 */
contract PurseRegistry {

    // ── Events ─────────────────────────────────

    event PurseCreated(
        address indexed owner,
        address indexed purseAddress,
        bytes32 indexed salt,
        string  name,
        address token,
        uint256 initialPrice
    );

    // ── Errors ─────────────────────────────────

    error DeployFailed();
    error PurseAlreadyExists(bytes32 salt);
    error NotPurseOwner();

    // ── Storage ────────────────────────────────

    /// purseAddress → exists
    mapping(address => bool) public isPurse;

    /// owner → list of purse addresses
    mapping(address => address[]) private _ownerPurses;

    /// salt → purse address (for duplicate detection)
    mapping(bytes32 => address) public purseOfSalt;

    // ── Create ─────────────────────────────────

    /**
     * @notice Deploy a new PurseWallet for msg.sender.
     *
     * @param name_        Purse display name.
     * @param description_ What is being sold (optional, pass "" to omit).
     * @param amount_      Price in token's smallest unit (wei for ETH).
     * @param token_       ERC-20 address, or address(0) for native ETH.
     * @param salt_        Arbitrary bytes32 chosen by the seller. Combined with
     *                     msg.sender to make the salt unique per account. Use a
     *                     UUID, keccak of a name, or a counter.
     *
     * @return purse The address of the newly deployed PurseWallet.
     *               This address goes into the QR code.
     */
    function createPurse(
        string  calldata name_,
        string  calldata description_,
        uint256 amount_,
        address token_,
        bytes32 salt_
    ) external returns (address purse) {
        // Personalise the salt so two sellers using the same salt_ don't clash
        bytes32 fullSalt = keccak256(abi.encodePacked(msg.sender, salt_));

        if (purseOfSalt[fullSalt] != address(0)) revert PurseAlreadyExists(fullSalt);

        // Deploy
        bytes memory bytecode = type(PurseWallet).creationCode;
        assembly {
            purse := create2(0, add(bytecode, 0x20), mload(bytecode), fullSalt)
        }
        if (purse == address(0)) revert DeployFailed();

        // Initialize
        IPurseWallet(purse).initialize(msg.sender, name_, description_, amount_, token_);

        // Register
        isPurse[purse]                  = true;
        purseOfSalt[fullSalt]           = purse;
        _ownerPurses[msg.sender].push(purse);

        emit PurseCreated(msg.sender, purse, fullSalt, name_, token_, amount_);
    }

    // ── Views ──────────────────────────────────

    /**
     * @notice All purse addresses owned by a seller.
     */
    function pursesOf(address owner_) external view returns (address[] memory) {
        return _ownerPurses[owner_];
    }

    /**
     * @notice Pre-compute the address a purse will land at before deploying.
     *         Use this to display the QR code before the tx confirms, or to
     *         verify an existing purse address.
     */
    function computePurseAddress(address owner_, bytes32 salt_) external view returns (address) {
        bytes32 fullSalt = keccak256(abi.encodePacked(owner_, salt_));
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                fullSalt,
                keccak256(type(PurseWallet).creationCode)
            )
        );
        return address(uint160(uint256(hash)));
    }

    /**
     * @notice Fetch info for multiple purses in one call.
     *         Returns parallel arrays — gas-efficient for frontend dashboards.
     */
    function batchInfo(address[] calldata purseAddresses)
        external
        view
        returns (
            address[] memory owners,
            string[]  memory names,
            string[]  memory descriptions,
            uint256[] memory prices,
            address[] memory tokens,
            uint256[] memory totals,
            uint256[] memory counts
        )
    {
        uint256 n = purseAddresses.length;
        owners       = new address[](n);
        names        = new string[](n);
        descriptions = new string[](n);
        prices       = new uint256[](n);
        tokens       = new address[](n);
        totals       = new uint256[](n);
        counts       = new uint256[](n);

        for (uint256 i; i < n; ++i) {
            PurseWallet w = PurseWallet(payable(purseAddresses[i]));
            owners[i]       = w.owner();
            names[i]        = w.name();
            descriptions[i] = w.description();
            prices[i]       = w.currentPrice();
            tokens[i]       = w.token();
            totals[i]       = w.totalReceived();
            counts[i]       = w.paymentCount();
        }
    }
}
