// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import '@openzeppelin/contracts/interfaces/IERC20.sol';

/// @dev https://snowtrace.io/address/0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE
interface ISAVAX is IERC20 {

  function getSharesByPooledAvax(uint avaxAmount) external view returns (uint);

  function getPooledAvaxByShares(uint sharesAmount) external view returns (uint);

}
