// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @dev Interface for the Rewards Proxy, designed to isolate the rewards claiming logic
/// from the logic of Spectra4626Wrapper instances.
interface IRewardsProxy {
    /// @notice Claims rewards based on the provided data.
    /// @dev This function should be called using `delegatecall`.
    /// @dev The implementation of this function should handle the logic for claiming rewards
    /// based on the input data. The specific format and structure of `data` should be defined
    /// by the implementation.
    /// @param data ABI-encoded data containing the necessary information to claim rewards.
    function claimRewards(bytes memory data) external;
}
