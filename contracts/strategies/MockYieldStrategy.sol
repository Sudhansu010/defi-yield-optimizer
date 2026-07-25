// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IYieldStrategy.sol";
import "../interfaces/IERC20.sol";

/// @title MockYieldStrategy
/// @notice Stand-in adapter for a real protocol (Aave / Compound / Uniswap / Curve).
///         On real Arc mainnet this contract would be replaced by a thin wrapper that
///         calls the actual protocol's deposit/withdraw functions. For the hackathon demo
///         on Arc testnet (where those protocols may not yet have liquid deployments),
///         this contract simulates realistic APY behaviour so the vault's rebalancing
///         logic can be fully exercised end-to-end.
///
///         Yield is simulated by a "reserve" of USDC pre-funded by the deployer
///         (e.g. from the testnet faucet). `accrueYield()` computes simple interest
///         based on elapsed time and the current APY, and moves that amount from the
///         reserve into the strategy's reportable `totalAssets`. No new tokens are
///         minted — everything is backed 1:1 by real testnet USDC sitting in the
///         contract.
contract MockYieldStrategy is IYieldStrategy {
    IERC20 public immutable asset; // USDC
    address public immutable vault;
    address public keeper; // allowed to update APY + trigger accrual (an oracle/bot in prod)

    string private _name;
    uint256 private _apyBps; // e.g. 420 = 4.20%
    uint256 private _principal; // USDC actually deposited by the vault
    uint256 private _accruedYield; // simulated yield earned on top of principal
    uint256 private _lastAccrualTimestamp;

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    event ApyUpdated(uint256 oldApyBps, uint256 newApyBps);
    event YieldAccrued(uint256 amount);
    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount);

    modifier onlyVault() {
        require(msg.sender == vault, "MockYieldStrategy: caller is not the vault");
        _;
    }

    modifier onlyKeeper() {
        require(msg.sender == keeper, "MockYieldStrategy: caller is not the keeper");
        _;
    }

    constructor(
        string memory name_,
        address asset_,
        address vault_,
        address keeper_,
        uint256 initialApyBps
    ) {
        _name = name_;
        asset = IERC20(asset_);
        vault = vault_;
        keeper = keeper_;
        _apyBps = initialApyBps;
        _lastAccrualTimestamp = block.timestamp;
    }

    // ---------- IYieldStrategy ----------

    function name() external view override returns (string memory) {
        return _name;
    }

    function currentApyBps() external view override returns (uint256) {
        return _apyBps;
    }

    function totalAssets() external view override returns (uint256) {
        return _principal + _accruedYield;
    }

    function deposit(uint256 amount) external override onlyVault {
        require(amount > 0, "MockYieldStrategy: zero deposit");
        _accrue();
        require(asset.transferFrom(vault, address(this), amount), "MockYieldStrategy: transferFrom failed");
        _principal += amount;
        emit Deposited(amount);
    }

    function withdraw(uint256 amount) external override onlyVault {
        _accrue();
        require(amount <= _principal + _accruedYield, "MockYieldStrategy: insufficient balance");
        _debit(amount);
        require(asset.transfer(vault, amount), "MockYieldStrategy: transfer failed");
        emit Withdrawn(amount);
    }

    function withdrawAll() external override onlyVault returns (uint256 withdrawn) {
        _accrue();
        withdrawn = _principal + _accruedYield;
        _principal = 0;
        _accruedYield = 0;
        if (withdrawn > 0) {
            require(asset.transfer(vault, withdrawn), "MockYieldStrategy: transfer failed");
        }
        emit Withdrawn(withdrawn);
    }

    // ---------- Keeper / oracle controls ----------

    /// @notice Update the simulated APY (in prod: read from the protocol's real rate).
    function setApyBps(uint256 newApyBps) external onlyKeeper {
        _accrue();
        emit ApyUpdated(_apyBps, newApyBps);
        _apyBps = newApyBps;
    }

    /// @notice Anyone can call this to pull in accrued yield (view-friendly, no access control needed
    ///         since it only ever increases reported balance up to what's actually in the contract).
    function accrueYield() external {
        _accrue();
    }

    function setKeeper(address newKeeper) external onlyKeeper {
        keeper = newKeeper;
    }

    // ---------- internal ----------

    function _accrue() internal {
        uint256 elapsed = block.timestamp - _lastAccrualTimestamp;
        if (elapsed == 0 || _principal == 0 || _apyBps == 0) {
            _lastAccrualTimestamp = block.timestamp;
            return;
        }
        uint256 interest = (_principal * _apyBps * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);

        // Cap accrual to whatever USDC the reserve actually holds in this contract,
        // so the strategy is always fully backed and can never promise more than it has.
        uint256 contractBalance = asset.balanceOf(address(this));
        uint256 alreadyOwed = _principal + _accruedYield;
        uint256 available = contractBalance > alreadyOwed ? contractBalance - alreadyOwed : 0;
        if (interest > available) {
            interest = available;
        }

        if (interest > 0) {
            _accruedYield += interest;
            emit YieldAccrued(interest);
        }
        _lastAccrualTimestamp = block.timestamp;
    }

    function _debit(uint256 amount) internal {
        // withdraw from accrued yield first, then principal
        if (amount <= _accruedYield) {
            _accruedYield -= amount;
        } else {
            uint256 remainder = amount - _accruedYield;
            _accruedYield = 0;
            _principal -= remainder;
        }
    }
}
