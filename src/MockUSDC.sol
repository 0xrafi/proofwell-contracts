// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice Test USDC token with public mint function for testnet
/// @dev Mimics USDC's 6 decimal places
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    /// @notice Returns 6 decimals like real USDC
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint tokens to any address (testnet only!)
    /// @param to Address to receive tokens
    /// @param amount Amount in smallest units (6 decimals)
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Convenience function to mint 100 USDC to caller
    function faucet() external {
        _mint(msg.sender, 100 * 10 ** 6); // 100 USDC
    }
}
