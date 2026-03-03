// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice Best-effort reconstruction from decompiled bytecode.
/// @dev This is not a byte-for-byte source recovery. Unknown selectors and
/// opaque admin paths are intentionally omitted unless they were clear enough
/// to restore safely. The exploitable mint path is preserved.

interface IERC20Like {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IMintableToken {
    function mint(address to, uint256 amount) external returns (bool);
}

interface ISwapHelper {
    function usdt() external view returns (address);
    function wbnb() external view returns (address);
    function getBNBPriceInUSDT() external view returns (uint256);
    function quoteTokenPriceInUSDT(address token) external view returns (uint256);
    function rewardToken() external view returns (address);
}

contract Mobius {
    struct TokenData {
        bool isReserveToken;
        bool isLiquidityToken;
        uint256 balance;
    }

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant GOVERNOR_ROLE = 0x7935bd0ae54bc31f548c14dba4d37c5c64b3f8ca900cb468fb8abd54d5894f55;
    bytes32 public constant MINTER_ROLE = 0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a6;
    bytes32 public constant REBASER_ROLE = 0x5fde63b561377d1441afa201ff619faac2ff8fed70a7fbdbe7a5cb07768c0b75;
    bytes32 public constant DEPOSIT_ROLE = 0x2561bf26f818282a3be40719542054d2173eb0d38539e8a8d3cff22f29fd2384;

    uint32 public versionCode;
    uint256 public epoch;
    uint256 public startTime;
    bool public isStarted;
    bool public enabled;
    bool public paused;

    address public caller;
    address public treasury;
    address public rewardHook;
    address public rewardToken;
    address public usdt;
    address public wbnb;
    address public mainLiquidityToken;
    address public swapHelper;

    uint256 public totalReserves;
    uint256 public mintedRewards;

    mapping(address => TokenData) public tokenData;
    mapping(address => uint256) public debtByAccount;
    address[] public reserveTokens;
    address[] public liquidityTokens;

    mapping(bytes32 => mapping(address => bool)) internal roles;
    mapping(bytes32 => bytes32) internal roleAdmins;

    event Deposit(address indexed userAddress, uint256 wantAmt, uint256 reserveValue, uint256 mintAmount);
    event Withdrawal(address indexed token, uint256 amount, uint256 reserveValue);
    event ReserveTokenAdded(address indexed reserve);
    event ReserveTokenRemoved(address indexed reserve);
    event RewardsMinted(address indexed operator, address indexed recipient, uint256 amount);
    event ReservesUpdated(uint256 newTotalReserves);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    error AccessDenied(bytes32 role, address account);
    error UnsupportedToken(address token);
    error InvalidAmount();
    error TransferFailed(address token);
    error MintFailed();

    modifier onlyRole(bytes32 role) {
        if (!roles[role][msg.sender]) revert AccessDenied(role, msg.sender);
        _;
    }

    modifier whenEnabled() {
        require(enabled, "disabled");
        _;
    }

    constructor(address owner_, address caller_, address helper_) {
        require(owner_ != address(0) && caller_ != address(0) && helper_ != address(0), "zero");

        roleAdmins[GOVERNOR_ROLE] = DEFAULT_ADMIN_ROLE;
        roleAdmins[MINTER_ROLE] = GOVERNOR_ROLE;
        roleAdmins[REBASER_ROLE] = GOVERNOR_ROLE;
        roleAdmins[DEPOSIT_ROLE] = GOVERNOR_ROLE;

        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(GOVERNOR_ROLE, owner_);
        _grantRole(GOVERNOR_ROLE, caller_);

        versionCode = 1;
        caller = caller_;
        swapHelper = helper_;
        enabled = true;

        usdt = ISwapHelper(helper_).usdt();
        wbnb = ISwapHelper(helper_).wbnb();
        rewardToken = ISwapHelper(helper_).rewardToken();

        tokenData[usdt].isReserveToken = true;
        tokenData[wbnb].isReserveToken = true;
        tokenData[mainLiquidityToken].isLiquidityToken = mainLiquidityToken != address(0);

        IERC20Like(rewardToken).approve(helper_, type(uint256).max);
        IERC20Like(usdt).approve(helper_, type(uint256).max);
        IERC20Like(wbnb).approve(helper_, type(uint256).max);
    }

    function grantRole(bytes32 role, address account) external onlyRole(roleAdmins[role]) {
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(roleAdmins[role]) {
        _revokeRole(role, account);
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }

    function addReserveToken(address reserve) external onlyRole(DEPOSIT_ROLE) whenEnabled {
        require(reserve != address(0), "zero");
        require(!tokenData[reserve].isReserveToken, "exists");
        tokenData[reserve].isReserveToken = true;
        reserveTokens.push(reserve);
        emit ReserveTokenAdded(reserve);
    }

    function removeReserveToken(address reserve) external onlyRole(DEPOSIT_ROLE) whenEnabled {
        require(tokenData[reserve].isReserveToken, "missing");
        require(tokenData[reserve].balance == 0, "balance");
        tokenData[reserve].isReserveToken = false;
        _removeFromArray(reserveTokens, reserve);
        emit ReserveTokenRemoved(reserve);
    }

    function isReserveToken(address token) public view returns (bool) {
        return tokenData[token].isReserveToken || token == usdt || token == wbnb;
    }

    function isLiquidityToken(address token) external view returns (bool) {
        return tokenData[token].isLiquidityToken || token == mainLiquidityToken;
    }

    /// @notice Restored from selector 0xb38635a2 -> internal 0x31ee
    function quoteMintAmount(address token, uint256 reserveValue) external view returns (uint256) {
        return _quoteMintAmount(token, reserveValue);
    }

    /// @notice Core exploitable path restored from selector 0x47e7ef24
    function deposit(address userAddress, uint256 wantAmt)
        external
        onlyRole(DEPOSIT_ROLE)
        whenEnabled
        returns (uint256 mintAmount)
    {
        if (!isReserveToken(userAddress) && !tokenData[userAddress].isLiquidityToken) {
            revert UnsupportedToken(userAddress);
        }
        if (wantAmt == 0) revert InvalidAmount();

        uint256 reserveValue = _quoteReserveValue(userAddress, wantAmt);
        require(reserveValue > 0, "zero reserve");

        mintAmount = _quoteMintAmount(userAddress, reserveValue);
        require(mintAmount > 0, "zero mint");

        _safeTransferFrom(userAddress, msg.sender, address(this), wantAmt);

        tokenData[userAddress].balance += wantAmt;
        if (tokenData[userAddress].isReserveToken) {
            totalReserves += reserveValue;
            emit ReservesUpdated(totalReserves);
        }

        bool ok = IMintableToken(rewardToken).mint(msg.sender, mintAmount);
        if (!ok) revert MintFailed();

        emit Deposit(userAddress, wantAmt, reserveValue, mintAmount);
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyRole(GOVERNOR_ROLE) {
        require(token != address(0) && amount != 0, "invalid");
        require(tokenData[token].balance >= amount, "insufficient");

        uint256 reserveValue = _quoteReserveValue(token, amount);
        if (tokenData[token].isReserveToken) {
            totalReserves -= reserveValue;
            emit ReservesUpdated(totalReserves);
        }

        tokenData[token].balance -= amount;
        _safeTransfer(token, msg.sender, amount);
        emit Withdrawal(token, amount, reserveValue);
    }

    function mintRewards(address recipient, uint256 amount)
        external
        onlyRole(MINTER_ROLE)
        returns (uint256)
    {
        require(recipient != address(0) && amount != 0, "invalid");
        require(amount <= excessReserves(), "excess");

        bool ok = IMintableToken(rewardToken).mint(recipient, amount);
        if (!ok) revert MintFailed();

        mintedRewards += amount;
        emit RewardsMinted(msg.sender, recipient, amount);
        return amount;
    }

    function excessReserves() public view returns (uint256) {
        if (totalReserves <= mintedRewards) return 0;
        return totalReserves - mintedRewards;
    }

    /// @dev Restored from internal 0x38d0
    function _quoteReserveValue(address token, uint256 amount) internal view returns (uint256) {
        if (token == usdt) {
            return amount;
        }
        if (token == wbnb) {
            uint256 bnbPrice = ISwapHelper(swapHelper).getBNBPriceInUSDT();
            return bnbPrice * amount;
        }
        return 0;
    }

    /// @dev Restored from internal 0x31ee
    /// The extra 1e18 factor is the over-mint bug.
    function _quoteMintAmount(address token, uint256 reserveValue) internal view returns (uint256) {
        require(token != address(0) && reserveValue != 0, "invalid");
        uint256 price = ISwapHelper(swapHelper).quoteTokenPriceInUSDT(rewardToken);
        require(price != 0, "zero price");
        return (reserveValue * 1e18) / price;
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        bool ok = IERC20Like(token).transferFrom(from, to, amount);
        if (!ok) revert TransferFailed(token);
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        bool ok = IERC20Like(token).transfer(to, amount);
        if (!ok) revert TransferFailed(token);
    }

    function _grantRole(bytes32 role, address account) internal {
        if (!roles[role][account]) {
            roles[role][account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }

    function _revokeRole(bytes32 role, address account) internal {
        if (roles[role][account]) {
            roles[role][account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }

    function _removeFromArray(address[] storage items, address target) internal {
        uint256 length = items.length;
        for (uint256 i = 0; i < length; i++) {
            if (items[i] == target) {
                items[i] = items[length - 1];
                items.pop();
                return;
            }
        }
    }
}
