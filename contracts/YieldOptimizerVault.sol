// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IERC20.sol";
import "./interfaces/IYieldStrategy.sol";

/// @title YieldOptimizerVault
/// @notice ERC-4626-style vault: users deposit USDC and receive shares representing
///         their portion of the vault's total assets. The vault spreads deposited USDC
///         across a set of registered yield strategies (Aave / Compound / Uniswap /
///         Curve style adapters) and can be rebalanced — by the owner or by anyone,
///         permissionlessly, once a rebalance is genuinely profitable — to concentrate
///         funds in whichever strategy currently reports the best risk-adjusted APY.
///
///         Built for Circle's Arc L1 (USDC-native gas, sub-second finality) as part of
///         the Encode "Programmable Money Hackathon".
contract YieldOptimizerVault {
    IERC20 public immutable usdc;
    address public owner;

    // --- ERC-4626-lite share accounting ---
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    // --- Strategy registry ---
    address[] public strategies;
    mapping(address => bool) public isRegisteredStrategy;

    // --- Risk controls ---
    /// @notice Max fraction (in bps) of total assets that may sit in a single strategy.
    ///         Keeps the vault from putting all funds in one risky pool chasing yield.
    uint256 public maxAllocationBps = 6000; // 60% cap per strategy by default

    uint256 private constant BPS_DENOMINATOR = 10_000;

    event Deposit(address indexed user, uint256 usdcAmount, uint256 sharesMinted);
    event Withdraw(address indexed user, uint256 usdcAmount, uint256 sharesBurned);
    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event Rebalanced(address indexed fromStrategy, address indexed toStrategy, uint256 amountMoved);
    event MaxAllocationUpdated(uint256 oldBps, uint256 newBps);
    event OwnerUpdated(address indexed oldOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Vault: caller is not the owner");
        _;
    }

    constructor(address usdc_) {
        usdc = IERC20(usdc_);
        owner = msg.sender;
    }

    // ---------------------------------------------------------------------
    // User-facing: deposit / withdraw
    // ---------------------------------------------------------------------

    /// @notice Deposit `amount` USDC and receive vault shares proportional to your
    ///         contribution. Idle USDC sits in the vault until an owner/keeper call
    ///         to `allocate` pushes it into a strategy (kept separate from deposit so
    ///         gas-sensitive users aren't forced to pay for a full rebalance on every deposit).
    function deposit(uint256 amount) external returns (uint256 sharesMinted) {
        require(amount > 0, "Vault: zero deposit");

        uint256 assetsBefore = totalAssets();
        require(usdc.transferFrom(msg.sender, address(this), amount), "Vault: transferFrom failed");

        sharesMinted = assetsBefore == 0 || totalShares == 0
            ? amount
            : (amount * totalShares) / assetsBefore;

        require(sharesMinted > 0, "Vault: rounds to zero shares");

        totalShares += sharesMinted;
        sharesOf[msg.sender] += sharesMinted;

        emit Deposit(msg.sender, amount, sharesMinted);
    }

    /// @notice Burn `shareAmount` shares and withdraw the corresponding USDC.
    ///         Pulls from idle vault balance first, then from strategies (largest first)
    ///         if idle liquidity isn't enough.
    function withdraw(uint256 shareAmount) external returns (uint256 amountWithdrawn) {
        require(shareAmount > 0, "Vault: zero withdraw");
        require(sharesOf[msg.sender] >= shareAmount, "Vault: insufficient shares");

        amountWithdrawn = (shareAmount * totalAssets()) / totalShares;

        sharesOf[msg.sender] -= shareAmount;
        totalShares -= shareAmount;

        _ensureIdleLiquidity(amountWithdrawn);

        require(usdc.transfer(msg.sender, amountWithdrawn), "Vault: transfer failed");
        emit Withdraw(msg.sender, amountWithdrawn, shareAmount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Total USDC value the vault controls: idle balance + everything deployed
    ///         across registered strategies.
    function totalAssets() public view returns (uint256 sum) {
        sum = usdc.balanceOf(address(this));
        uint256 len = strategies.length;
        for (uint256 i = 0; i < len; i++) {
            sum += IYieldStrategy(strategies[i]).totalAssets();
        }
    }

    /// @notice Convenience view: current USDC value of `user`'s position.
    function balanceOf(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (sharesOf[user] * totalAssets()) / totalShares;
    }

    /// @notice Returns every registered strategy alongside its current APY and balance —
    ///         everything the frontend dashboard needs in one call.
    function getStrategyData()
        external
        view
        returns (
            address[] memory addrs,
            string[] memory names,
            uint256[] memory apyBps,
            uint256[] memory balances
        )
    {
        uint256 len = strategies.length;
        addrs = new address[](len);
        names = new string[](len);
        apyBps = new uint256[](len);
        balances = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            IYieldStrategy s = IYieldStrategy(strategies[i]);
            addrs[i] = strategies[i];
            names[i] = s.name();
            apyBps[i] = s.currentApyBps();
            balances[i] = s.totalAssets();
        }
    }

    function strategiesCount() external view returns (uint256) {
        return strategies.length;
    }

    // ---------------------------------------------------------------------
    // Owner: strategy management
    // ---------------------------------------------------------------------

    function addStrategy(address strategy) external onlyOwner {
        require(strategy != address(0), "Vault: zero address");
        require(!isRegisteredStrategy[strategy], "Vault: already registered");
        isRegisteredStrategy[strategy] = true;
        strategies.push(strategy);
        emit StrategyAdded(strategy);
    }

    function removeStrategy(address strategy) external onlyOwner {
        require(isRegisteredStrategy[strategy], "Vault: not registered");
        // Pull all funds out before de-registering.
        uint256 withdrawn = IYieldStrategy(strategy).withdrawAll();
        isRegisteredStrategy[strategy] = false;

        uint256 len = strategies.length;
        for (uint256 i = 0; i < len; i++) {
            if (strategies[i] == strategy) {
                strategies[i] = strategies[len - 1];
                strategies.pop();
                break;
            }
        }
        emit StrategyRemoved(strategy);
        emit Withdraw(address(this), withdrawn, 0);
    }

    function setMaxAllocationBps(uint256 newBps) external onlyOwner {
        require(newBps <= BPS_DENOMINATOR, "Vault: bps too high");
        emit MaxAllocationUpdated(maxAllocationBps, newBps);
        maxAllocationBps = newBps;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Vault: zero address");
        emit OwnerUpdated(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Push idle (undeployed) USDC sitting in the vault into `strategy`.
    function allocate(address strategy, uint256 amount) public onlyOwner {
        require(isRegisteredStrategy[strategy], "Vault: unknown strategy");
        require(amount <= usdc.balanceOf(address(this)), "Vault: insufficient idle balance");
        _enforceCap(strategy, amount);

        usdc.approve(strategy, amount);
        IYieldStrategy(strategy).deposit(amount);
    }

    // ---------------------------------------------------------------------
    // Rebalancing — the "optimizer" part
    // ---------------------------------------------------------------------

    /// @notice Anyone can call this (e.g. a keeper bot, or a judge clicking the demo
    ///         button) to move funds from the lowest-APY strategy into the highest-APY
    ///         one. Only moves funds if the APY gap clears `minImprovementBps`, so the
    ///         vault doesn't churn gas on negligible differences.
    function rebalance(uint256 minImprovementBps) external returns (bool moved) {
        uint256 len = strategies.length;
        require(len >= 2, "Vault: need at least 2 strategies to rebalance");

        (uint256 bestIdx, uint256 bestApy) = _bestStrategy();
        (uint256 worstIdx, uint256 worstApy, uint256 worstBalance) = _worstFundedStrategy();

        if (bestIdx == worstIdx || worstBalance == 0) return false;
        if (bestApy < worstApy + minImprovementBps) return false;

        address from = strategies[worstIdx];
        address to = strategies[bestIdx];

        uint256 amount = worstBalance;
        IYieldStrategy(from).withdraw(amount);

        // Respect the concentration cap even during rebalancing.
        uint256 idleNow = usdc.balanceOf(address(this));
        uint256 moveAmount = amount > idleNow ? idleNow : amount;
        _enforceCap(to, moveAmount);

        usdc.approve(to, moveAmount);
        IYieldStrategy(to).deposit(moveAmount);

        emit Rebalanced(from, to, moveAmount);
        return true;
    }

    // ---------------------------------------------------------------------
    // internal helpers
    // ---------------------------------------------------------------------

    function _bestStrategy() internal view returns (uint256 bestIdx, uint256 bestApy) {
        uint256 len = strategies.length;
        bestApy = 0;
        for (uint256 i = 0; i < len; i++) {
            uint256 apy = IYieldStrategy(strategies[i]).currentApyBps();
            if (apy >= bestApy) {
                bestApy = apy;
                bestIdx = i;
            }
        }
    }

    function _worstFundedStrategy()
        internal
        view
        returns (uint256 worstIdx, uint256 worstApy, uint256 worstBalance)
    {
        uint256 len = strategies.length;
        worstApy = type(uint256).max;
        for (uint256 i = 0; i < len; i++) {
            IYieldStrategy s = IYieldStrategy(strategies[i]);
            uint256 bal = s.totalAssets();
            if (bal == 0) continue;
            uint256 apy = s.currentApyBps();
            if (apy <= worstApy) {
                worstApy = apy;
                worstIdx = i;
                worstBalance = bal;
            }
        }
        if (worstApy == type(uint256).max) worstApy = 0;
    }

    function _enforceCap(address strategy, uint256 incomingAmount) internal view {
        uint256 total = totalAssets();
        if (total == 0) return;
        uint256 projected = IYieldStrategy(strategy).totalAssets() + incomingAmount;
        require(
            (projected * BPS_DENOMINATOR) / total <= maxAllocationBps,
            "Vault: exceeds max allocation cap"
        );
    }

    /// @notice If idle balance can't cover a withdrawal, pull the shortfall out of
    ///         strategies, starting with whichever currently has the lowest APY
    ///         (so we disturb the best-performing position last).
    function _ensureIdleLiquidity(uint256 amountNeeded) internal {
        uint256 idle = usdc.balanceOf(address(this));
        if (idle >= amountNeeded) return;

        uint256 shortfall = amountNeeded - idle;

        // Simple ascending-APY pass: withdraw from lowest-APY strategies first.
        uint256 len = strategies.length;
        for (uint256 pass = 0; pass < len && shortfall > 0; pass++) {
            uint256 lowestIdx = 0;
            uint256 lowestApy = type(uint256).max;
            bool found = false;

            for (uint256 i = 0; i < len; i++) {
                IYieldStrategy s = IYieldStrategy(strategies[i]);
                if (s.totalAssets() == 0) continue;
                uint256 apy = s.currentApyBps();
                if (apy < lowestApy) {
                    lowestApy = apy;
                    lowestIdx = i;
                    found = true;
                }
            }
            if (!found) break;

            IYieldStrategy s = IYieldStrategy(strategies[lowestIdx]);
            uint256 available = s.totalAssets();
            uint256 pull = shortfall < available ? shortfall : available;
            s.withdraw(pull);
            shortfall -= pull;
        }
    }
}
