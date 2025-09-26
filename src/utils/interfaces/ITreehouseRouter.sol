// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.20;

interface ITreehouseRouter {
  error DepositCapExceeded();
  error NotAllowableAsset();
  error NoSharesMinted();
  error ConversionToUnderlyingFailed();
  error InvalidSender();

  event Deposited(address _asset, uint _amountInUnderlying, uint _shares);
  event DepositCapUpdated(uint _newDepositCap, uint _oldDepositCap);

  function deposit(address _asset, uint256 _amount) external;

  function depositAVAX() external payable;
}
