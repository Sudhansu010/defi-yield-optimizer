// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IYieldStrategy
/// @notice Common interface every protocol adapter (Aave, Compound, Uniswap, Curve, ...)
///         must implement so the vault can treat them interchangeably.
interface IYieldStrategy {
    /// @notice Human readable name, e.g. "Aave USDC Pool"
    function name() external view returns (string memory);

    /// @notice Current supply APY in basis points (1% = 100 bps). In production this
    ///         would read the protocol's real-time rate; here it is provided by an
    ///         oracle/keeper via `setApy` so the vault logic can be demoed end-to-end.
    function currentApyBps() external view returns (uint256);

    /// @notice Total underlying (USDC) this strategy currently holds on behalf of the vault.
    function totalAssets() external view returns (uint256);

    /// @notice Pull `amount` of USDC from the vault and deposit it into the underlying protocol.
    /// @dev Vault must approve this strategy for `amount` before calling.
    function deposit(uint256 amount) external;

    /// @notice Withdraw `amount` of USDC from the underlying protocol back to the vault.
    function withdraw(uint256 amount) external;

    /// @notice Withdraw everything back to the vault (used when the vault fully exits a strategy).
    function withdrawAll() external returns (uint256 withdrawn);
}
