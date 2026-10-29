// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-20 surface used by the Shield.
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Price adapter. Returns the USD value of `amount` of `token`, with 6 decimals.
/// Must revert for tokens it cannot price.
interface IKX9PriceOracle {
    function usdValue(address token, uint256 amount) external view returns (uint256 usd6);
}

/// @title KX9Shield
/// @notice One vault per KX-9 unit. The operator owns the funds and the limits.
///         The executor (a session key run by the KX-9 relayer) can only swap inside the limits
///         and can never withdraw. Standby can always be set by the operator.
contract KX9Shield {
    // ------------------------------------------------------------------ types
    enum Mode { Supervised, Autonomous, Standby }

    struct Limits {
        uint256 maxTradeUsd;  // 6 decimals
        uint256 dailyCapUsd;  // 6 decimals
        uint16 slippageBps;   // 80 = 0.80%
        uint32 cooldownSec;
    }

    struct TradeIntent {
        bytes32 proposalId;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        uint64 deadline;
    }

    struct Approval {
        uint256 maxUsd;   // 6 decimals
        uint64 deadline;
        bool used;
    }

    // ------------------------------------------------------------- reasons
    uint8 internal constant NOT_WHITELISTED = 1;
    uint8 internal constant MAX_TRADE = 2;
    uint8 internal constant DAILY_CAP = 3;
    uint8 internal constant SLIPPAGE = 4;
    uint8 internal constant COOLDOWN = 5;
    uint8 internal constant STANDBY = 6;
    uint8 internal constant CLASS_REQUIRED = 7;
    uint8 internal constant NOT_APPROVED = 8;

    error Blocked(uint8 reason);
    error NotOperator();
    error NotExecutor();
    error BadLimits();
    error Expired();
    error RouterNotAllowed();
    error SwapFailed();
    error TransferFailed();
    error Reentrancy();

    // ------------------------------------------------------------- bounds (match docs/app)
    uint256 public constant MIN_MAX_TRADE = 50e6;
    uint256 public constant MAX_MAX_TRADE = 5_000e6;
    uint256 public constant MIN_DAILY_CAP = 100e6;
    uint256 public constant MAX_DAILY_CAP = 20_000e6;
    uint16 public constant MIN_SLIPPAGE = 10;   // 0.1%
    uint16 public constant MAX_SLIPPAGE = 300;  // 3.0%
    uint32 public constant MAX_COOLDOWN = 120 minutes;

    // ------------------------------------------------------------- storage
    uint256 public immutable agentId;
    address public immutable factory;
    IKX9PriceOracle public immutable oracle;
    IERC20 public immutable accessToken;            // $KX9, may be address(0) before launch
    uint256 public immutable autonomousMinBalance;  // Mk II threshold, 0 = not enforced

    address public operator;
    address public executor;
    Mode public mode;
    Limits internal _limits;
    bool public customRanges;                       // Mk III: operator opted out of default ranges

    mapping(address => bool) public whitelisted;
    mapping(address => bool) public routerAllowed;
    mapping(bytes32 => Approval) public approvals;

    uint256 public usedDay;     // UTC day index of usedTodayUsd
    uint256 public usedTodayUsd;
    uint64 public lastTradeAt;
    uint256 private _lock = 1;

    // ------------------------------------------------------------- events
    event LimitsUpdated(uint256 indexed agentId, Limits limits);
    event WhitelistUpdated(uint256 indexed agentId, address token, bool allowed);
    event RouterUpdated(uint256 indexed agentId, address router, bool allowed);
    event ModeChanged(uint256 indexed agentId, Mode mode);
    event ExecutorChanged(uint256 indexed agentId, address executor);
    event OperatorChanged(uint256 indexed agentId, address operator);
    event ProposalApproved(uint256 indexed agentId, bytes32 indexed proposalId, uint256 maxUsd, uint64 deadline);
    event ProposalRevoked(uint256 indexed agentId, bytes32 indexed proposalId);
    event TradeExecuted(uint256 indexed agentId, bytes32 indexed proposalId, address tokenIn, address tokenOut,
        uint256 amountIn, uint256 amountOut, uint256 usdValue);
    event Withdrawn(uint256 indexed agentId, address token, uint256 amount, address to);

    modifier onlyOperator() { if (msg.sender != operator) revert NotOperator(); _; }
    modifier nonReentrant() { if (_lock != 1) revert Reentrancy(); _lock = 2; _; _lock = 1; }

    constructor(
        uint256 agentId_,
        address operator_,
        address executor_,
        IKX9PriceOracle oracle_,
        IERC20 accessToken_,
        uint256 autonomousMinBalance_,
        Limits memory limits_,
        address[] memory whitelist_,
        address[] memory routers_
    ) {
        agentId = agentId_;
        factory = msg.sender;
        operator = operator_;
        executor = executor_;
        oracle = oracle_;
        accessToken = accessToken_;
        autonomousMinBalance = autonomousMinBalance_;
        _checkLimits(limits_);
        _limits = limits_;
        for (uint256 i; i < whitelist_.length; ++i) whitelisted[whitelist_[i]] = true;
        for (uint256 i; i < routers_.length; ++i) routerAllowed[routers_[i]] = true;
        mode = Mode.Supervised;
        emit LimitsUpdated(agentId_, limits_);
        emit ModeChanged(agentId_, Mode.Supervised);
    }

    receive() external payable {}

    // ------------------------------------------------------------- views
    function limits() external view returns (Limits memory) { return _limits; }

    function usedToday() public view returns (uint256) {
        return usedDay == block.timestamp / 1 days ? usedTodayUsd : 0;
    }

    function canAutonomous(address who) public view returns (bool) {
        if (address(accessToken) == address(0) || autonomousMinBalance == 0) return true;
        return accessToken.balanceOf(who) >= autonomousMinBalance;
    }

    // ------------------------------------------------------------- operator
    function setLimits(Limits calldata l) external onlyOperator {
        _checkLimits(l);
        _limits = l;
        emit LimitsUpdated(agentId, l);
    }

    function setCustomRanges(bool on) external onlyOperator { customRanges = on; }

    function setWhitelist(address token, bool allowed) external onlyOperator {
        whitelisted[token] = allowed;
        emit WhitelistUpdated(agentId, token, allowed);
    }

    function setRouter(address router, bool allowed) external onlyOperator {
        routerAllowed[router] = allowed;
        emit RouterUpdated(agentId, router, allowed);
    }

    /// @notice Standby is always allowed. Autonomous needs the unit class (Mk II+).
    function setMode(Mode m) external onlyOperator {
        if (m == Mode.Autonomous && !canAutonomous(operator)) revert Blocked(CLASS_REQUIRED);
        mode = m;
        emit ModeChanged(agentId, m);
    }

    function setExecutor(address e) external onlyOperator {
        executor = e;
        emit ExecutorChanged(agentId, e);
    }

    function transferOperator(address o) external onlyOperator {
        require(o != address(0), "zero");
        operator = o;
        emit OperatorChanged(agentId, o);
    }

    /// @notice Supervised mode: the operator approves one proposal, capped in USD and time.
    function approveProposal(bytes32 proposalId, uint256 maxUsd, uint64 deadline) external onlyOperator {
        if (deadline <= block.timestamp) revert Expired();
        approvals[proposalId] = Approval(maxUsd, deadline, false);
        emit ProposalApproved(agentId, proposalId, maxUsd, deadline);
    }

    function revokeProposal(bytes32 proposalId) external onlyOperator {
        delete approvals[proposalId];
        emit ProposalRevoked(agentId, proposalId);
    }

    function withdraw(address token, uint256 amount, address to) external onlyOperator nonReentrant {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            _safeTransfer(token, to, amount);
        }
        emit Withdrawn(agentId, token, amount, to);
    }

    // ------------------------------------------------------------- executor
    /// @notice Swap through an allowed router. Every Shield rule is checked here, on-chain.
    /// @param router  allowed DEX router
    /// @param routerCalldata  swap call built off-chain; output must land in this vault
    function execute(TradeIntent calldata t, address router, bytes calldata routerCalldata)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (msg.sender != executor) revert NotExecutor();
        if (block.timestamp > t.deadline) revert Expired();
        if (mode == Mode.Standby) revert Blocked(STANDBY);
        if (!routerAllowed[router]) revert RouterNotAllowed();
        if (!whitelisted[t.tokenIn] || !whitelisted[t.tokenOut]) revert Blocked(NOT_WHITELISTED);

        Limits memory l = _limits;
        uint256 usdIn = oracle.usdValue(t.tokenIn, t.amountIn);
        if (usdIn > l.maxTradeUsd) revert Blocked(MAX_TRADE);

        uint256 today = block.timestamp / 1 days;
        uint256 used = usedDay == today ? usedTodayUsd : 0;
        if (used + usdIn > l.dailyCapUsd) revert Blocked(DAILY_CAP);
        if (lastTradeAt != 0 && block.timestamp < uint256(lastTradeAt) + l.cooldownSec) revert Blocked(COOLDOWN);

        if (mode == Mode.Supervised) {
            Approval storage a = approvals[t.proposalId];
            if (a.used || a.deadline < block.timestamp || usdIn > a.maxUsd) revert Blocked(NOT_APPROVED);
            a.used = true;
        } else if (!canAutonomous(operator)) {
            revert Blocked(CLASS_REQUIRED);
        }

        uint256 beforeOut = IERC20(t.tokenOut).balanceOf(address(this));
        _forceApprove(t.tokenIn, router, t.amountIn);
        (bool ok,) = router.call(routerCalldata);
        _forceApprove(t.tokenIn, router, 0);
        if (!ok) revert SwapFailed();
        amountOut = IERC20(t.tokenOut).balanceOf(address(this)) - beforeOut;

        if (amountOut < t.minAmountOut) revert Blocked(SLIPPAGE);
        uint256 usdOut = oracle.usdValue(t.tokenOut, amountOut);
        if (usdOut * 10_000 < usdIn * (10_000 - l.slippageBps)) revert Blocked(SLIPPAGE);

        usedDay = today;
        usedTodayUsd = used + usdIn;
        lastTradeAt = uint64(block.timestamp);
        emit TradeExecuted(agentId, t.proposalId, t.tokenIn, t.tokenOut, t.amountIn, amountOut, usdIn);
    }

    // ------------------------------------------------------------- internal
    function _checkLimits(Limits memory l) internal view {
        if (l.slippageBps == 0 || l.slippageBps > 1_000 || l.maxTradeUsd > l.dailyCapUsd) revert BadLimits();
        if (customRanges) return;
        if (l.maxTradeUsd < MIN_MAX_TRADE || l.maxTradeUsd > MAX_MAX_TRADE) revert BadLimits();
        if (l.dailyCapUsd < MIN_DAILY_CAP || l.dailyCapUsd > MAX_DAILY_CAP) revert BadLimits();
        if (l.slippageBps < MIN_SLIPPAGE || l.slippageBps > MAX_SLIPPAGE) revert BadLimits();
        if (l.cooldownSec > MAX_COOLDOWN) revert BadLimits();
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _forceApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) {
            (ok, data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, 0));
            (ok, data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
            if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
        }
    }
}
