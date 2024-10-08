// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @title IWeirollWallet
/// @author Royco
interface IWeirollWallet {
    /// @notice Let the Weiroll Wallet receive ether directly if needed
    receive() external payable;
    /// @notice Also allow a fallback with no logic if erroneous data is provided
    fallback() external payable;

    /// @notice The address of the order creator (owner)
    function owner() external pure returns (address);

    /// @notice The address of the recipeKernel exchange contract
    function recipeKernel() external pure returns (address);

    /// @notice The amount of tokens deposited into this wallet from the recipeKernel
    function amount() external pure returns (uint256);

    /// @notice The timestamp after which the wallet may be interacted with
    function lockedUntil() external pure returns (uint256);

    /// @notice Returns the marketId associated with this weiroll wallet
    function marketId() external pure returns (uint256);

    function executeWeiroll(bytes32[] calldata commands, bytes[] calldata state)
        external
        payable
        returns (bytes[] memory);
}
