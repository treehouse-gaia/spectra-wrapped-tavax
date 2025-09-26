// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Spectra4626Wrapper, ERC4626Upgradeable} from "../utils/Spectra4626Wrapper.sol";
import {ITreehouseRouter} from "../utils/interfaces/ITreehouseRouter.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SpectraWrappedtAVAX - Implementation of Spectra ERC4626 wrapper for tAVAX
/// @notice This contract wraps the tAVAX with the ERC4626 interface
/// @notice The contract is instantiated with the vault address, the underlying address
/// @notice and the initial authority.
contract SpectraWrappedtAVAX is Spectra4626Wrapper {
    using Math for uint256;
    using SafeERC20 for IERC20;

    address public  wAVAX;
    address public  sAVAX;
    address public  treehouseRouter;

    error WithdrawNotImplemented();
    error RedeemNotImplemented();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _wavax,
        address _savax,
        address _tavax,
        address _treehouseRouter,
        address _initAuth
    ) external initializer {
        __Spectra4626Wrapper_init(_wavax, _tavax, _initAuth);
        IERC20(_wavax).forceApprove(_treehouseRouter, type(uint256).max);
        wAVAX = _wavax;
        sAVAX = _savax;
        treehouseRouter = _treehouseRouter;
    }

    /*//////////////////////////////////////////////////////////////
                        ERC4626 GETTERS
    //////////////////////////////////////////////////////////////*/

    /** @dev See {IERC4626-maxDeposit}. */
    function maxDeposit(
        address
    ) public view override(IERC4626, ERC4626Upgradeable) returns (uint256) {
        return uint256(type(int256).max);
    }

    /** @dev See {IERC4626-maxMint}. */
    function maxMint(address) public view override(IERC4626, ERC4626Upgradeable) returns (uint256) {
        return uint256(type(int256).max);
    }

    /// @dev See {IERC4626-maxWithdraw}. */
    function maxWithdraw(
        address /*owner*/
    ) public view override(IERC4626, ERC4626Upgradeable) returns (uint256) {
        return 0;
    }

    /// @dev See {IERC4626-maxRedeem}. */
    function maxRedeem(
        address /*owner*/
    ) public view override(IERC4626, ERC4626Upgradeable) returns (uint256) {
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                    ERC4626 PUBLIC OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @dev See {IERC4626-withdraw}.
    /// @notice We decided to revert the withdraw as the user can unwrap the shares.
    function withdraw(
        uint256 /*assets*/,
        address /*receiver*/,
        address /*owner*/
    ) public override(IERC4626, ERC4626Upgradeable) returns (uint256) {
        revert WithdrawNotImplemented();
    }

    /// @dev See {IERC4626-redeem}.
    /// @notice We decided to revert the withdraw as the user can unwrap the shares.
    function redeem(
        uint256 /*shares*/,
        address /*receiver*/,
        address /*owner*/
    ) public override(IERC4626, ERC4626Upgradeable) returns (uint256) {
        revert RedeemNotImplemented();
    }

    /*//////////////////////////////////////////////////////////////
                    ERC4626 INTERNAL OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @dev Internal conversion function (from assets to shares) with support for rounding direction.
    /// @param assets The amount of assets to convert.
    /// @param rounding The rounding direction to use.
    /// @return The amount of shares.
    function _convertToShares(
        uint256 assets,
        Math.Rounding rounding
    ) internal view override(ERC4626Upgradeable) returns (uint256) {
        uint256 sAVAXAmount =  IERC4626(sAVAX).convertToShares(assets);
        uint256 vaultSharesAmount = IERC4626(vaultShare()).convertToShares(sAVAXAmount);
        return _previewWrap(vaultSharesAmount, rounding);
    }

    /// @dev Internal conversion function (from shares to assets) with support for rounding direction.
    /// @param shares The amount of shares to convert.
    /// @param rounding The rounding direction to use.
    /// @return The amount of assets.
    function _convertToAssets(
        uint256 shares,
        Math.Rounding rounding
    ) internal view override(ERC4626Upgradeable) returns (uint256) {
        uint256 vaultSharesAmount = _previewUnwrap(shares, rounding);
        uint256 sAVAXAmount = IERC4626(vaultShare()).convertToAssets(vaultSharesAmount);
        return IERC4626(sAVAX).convertToAssets(sAVAXAmount);
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override(ERC4626Upgradeable) {
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, address(this), assets);
        _wrapperDeposit(assets);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Internal function to mint tAVAX shares by first depositing in the sAVAX vault.
    function _wrapperDeposit(uint256 amount) internal {
        if (amount != 0) {
            // Treehouse router handles the deposit of wAVAX into sAVAX and then into tAVAX. Returns tAVAX to this contract.
            ITreehouseRouter(treehouseRouter).deposit(wAVAX, amount);
        }
    }
}
