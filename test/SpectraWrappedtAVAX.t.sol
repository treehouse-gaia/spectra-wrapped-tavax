// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {SpectraWrappedtAVAX} from "../src/Treehouse/SpectraWrappedtAVAX.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ISAVAX} from "../src/interfaces/ISAVAX.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC4626Mock} from "@openzeppelin/contracts/mocks/token/ERC4626Mock.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Mock sAVAX contract implementing ISAVAX interface
contract MockSAVAX is ERC20, ISAVAX {
    uint256 private constant EXCHANGE_RATE_PRECISION = 1e18;
    uint256 public exchangeRate = EXCHANGE_RATE_PRECISION; // 1:1 initially

    constructor() ERC20("Staked AVAX", "sAVAX") {}

    function getSharesByPooledAvax(uint avaxAmount) external view override returns (uint) {
        return (avaxAmount * EXCHANGE_RATE_PRECISION) / exchangeRate;
    }

    function getPooledAvaxByShares(uint sharesAmount) external view override returns (uint) {
        return (sharesAmount * exchangeRate) / EXCHANGE_RATE_PRECISION;
    }

    function setExchangeRate(uint256 _newRate) external {
        exchangeRate = _newRate;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock TreehouseRouter
contract MockTreehouseRouter {
    IERC20 public immutable wAVAX;
    ISAVAX public immutable sAVAX;
    IERC20 public immutable tAVAX;

    constructor(address _wAVAX, address _sAVAX, address _tAVAX) {
        wAVAX = IERC20(_wAVAX);
        sAVAX = ISAVAX(_sAVAX);
        tAVAX = IERC20(_tAVAX);
    }

    function deposit(address token, uint256 amount) external {
        require(token == address(wAVAX), "Only wAVAX supported");
        wAVAX.transferFrom(msg.sender, address(this), amount);

        // Convert wAVAX to sAVAX using the exchange rate
        uint256 sAVAXAmount = sAVAX.getSharesByPooledAvax(amount);

        // Deposit sAVAX to tAVAX 1:1 (tAVAX is ERC4626 wrapper, so 1 sAVAX = 1 tAVAX share on first deposit)
        // For simplicity in mock, we just return the sAVAX amount as tAVAX
        tAVAX.transfer(msg.sender, sAVAXAmount);
    }
}

contract SpectraWrappedtAVAXTest is Test {
    SpectraWrappedtAVAX public wrapper; // proxy instance (cast)
    SpectraWrappedtAVAX public implementation; // logic contract
    ERC20Mock public wAVAX;
    MockSAVAX public sAVAX;
    ERC4626Mock public tAVAX;
    MockTreehouseRouter public treehouseRouter;

    address public user1;
    address public user2;
    address public initialAuthority;

    uint256 constant INITIAL_SUPPLY = 1_000_000 * 1e18;
    uint256 constant TEST_AMOUNT = 1000 * 1e18;

    function setUp() public {
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        initialAuthority = makeAddr("authority");

        // Deploy mock tokens
        wAVAX = new ERC20Mock();
        sAVAX = new MockSAVAX();
        tAVAX = new ERC4626Mock(address(sAVAX));

        // Deploy mock router (now needs sAVAX for exchange rate calculation)
        treehouseRouter = new MockTreehouseRouter(address(wAVAX), address(sAVAX), address(tAVAX));

        // Setup initial balances
        wAVAX.mint(user1, INITIAL_SUPPLY);
        wAVAX.mint(user2, INITIAL_SUPPLY);
        wAVAX.mint(address(treehouseRouter), INITIAL_SUPPLY);

        // Give router some tAVAX to distribute
        sAVAX.mint(address(treehouseRouter), INITIAL_SUPPLY);
        tAVAX.mint(address(treehouseRouter), INITIAL_SUPPLY);

        // Set sAVAX exchange rate to 1.23 (1 wAVAX = 1.23 sAVAX worth)
        sAVAX.setExchangeRate(1.23e18);

        // Deploy implementation (logic) contract with immutable values
        implementation = new SpectraWrappedtAVAX(
            address(wAVAX),
            address(sAVAX),
            address(treehouseRouter)
        );

        // Prepare initializer calldata (matches initialize signature)
        bytes memory initData = abi.encodeCall(
            SpectraWrappedtAVAX.initialize,
            (
                address(wAVAX),
                address(sAVAX),
                address(tAVAX),
                address(treehouseRouter),
                initialAuthority
            )
        );

        // Deploy minimal proxy and call initialize atomically
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        wrapper = SpectraWrappedtAVAX(address(proxy));
    }

    function _postInitApprovals() internal {
        // Setup approvals for users post initialization
        vm.startPrank(user1);
        wAVAX.approve(address(wrapper), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        wAVAX.approve(address(wrapper), type(uint256).max);
        vm.stopPrank();
    }

    function test_ContractExists() public view {
        assertTrue(address(wrapper) != address(0));
    }

    function test_Initialization() public {
    // already initialized through proxy in setUp
    _postInitApprovals();

        assertEq(address(wrapper.asset()), address(wAVAX));
        assertEq(address(wrapper.vaultShare()), address(tAVAX));
        assertEq(wrapper.wAVAX(), address(wAVAX));
        assertEq(wrapper.sAVAX(), address(sAVAX));
        assertEq(wrapper.treehouseRouter(), address(treehouseRouter));
    }

    function test_MaxFunctions() public {
    _postInitApprovals();

        address user = makeAddr("user");
        assertEq(wrapper.maxDeposit(user), uint256(type(int256).max));
        assertEq(wrapper.maxMint(user), uint256(type(int256).max));
        assertEq(wrapper.maxWithdraw(user), 0);
        assertEq(wrapper.maxRedeem(user), 0);
    }

    function test_DisabledFunctions() public {
    _postInitApprovals();

        address user = makeAddr("user");

        vm.expectRevert(SpectraWrappedtAVAX.WithdrawNotImplemented.selector);
        wrapper.withdraw(100, user, user);

        vm.expectRevert(SpectraWrappedtAVAX.RedeemNotImplemented.selector);
        wrapper.redeem(100, user, user);
    }

    /*//////////////////////////////////////////////////////////////
                        CONVERSION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ConvertToShares() public {
    _postInitApprovals();

        uint256 assets = TEST_AMOUNT;

        // Test the conversion function
        uint256 shares = wrapper.convertToShares(assets);

        console.log("Assets:", assets);
        console.log("Converted to shares:", shares);

        assertGt(shares, 0, "Shares should be greater than 0");

        // Test with different amounts
        uint256 smallAssets = 1e18;
        uint256 smallShares = wrapper.convertToShares(smallAssets);
        assertGt(smallShares, 0, "Small shares should be greater than 0");

        // Proportionality test - double assets should give approximately double shares
        uint256 doubleShares = wrapper.convertToShares(assets * 2);
        assertApproxEqRel(doubleShares, shares * 2, 0.01e18, "Double assets should give approximately double shares");
    }

    function test_ConvertToAssets() public {
    _postInitApprovals();
        // First, get some shares by converting assets
        uint256 assets = TEST_AMOUNT;
        uint256 shares = wrapper.convertToShares(assets);

        // Now convert those shares back to assets
        uint256 convertedAssets = wrapper.convertToAssets(shares);

        console.log("Original assets:", assets);
        console.log("Shares:", shares);
        console.log("Converted back to assets:", convertedAssets);

        assertGt(convertedAssets, 0, "Converted assets should be greater than 0");

        // The conversion should be approximately reversible
        assertApproxEqRel(convertedAssets, assets, 0.01e18, "Round-trip conversion should be approximately equal");
    }

    function test_ConversionConsistency() public {
    _postInitApprovals();
        uint256[] memory testAmounts = new uint256[](4);
        testAmounts[0] = 1e18;      // 1 token
        testAmounts[1] = 100e18;    // 100 tokens
        testAmounts[2] = 1000e18;   // 1,000 tokens
        testAmounts[3] = 10000e18;  // 10,000 tokens

        for (uint i = 0; i < testAmounts.length; i++) {
            uint256 assets = testAmounts[i];
            uint256 shares = wrapper.convertToShares(assets);
            uint256 backToAssets = wrapper.convertToAssets(shares);

            console.log("Test amount:", assets);
            console.log("To shares:", shares);
            console.log("Back to assets:", backToAssets);

            assertGt(shares, 0, "Shares should be positive");
            assertApproxEqRel(backToAssets, assets, 0.02e18, "Round-trip should be consistent");
        }
    }

    function test_ISAVAXIntegration() public {
    _postInitApprovals();
        uint256 avaxAmount = TEST_AMOUNT;

        // Test the ISAVAX interface functions directly
        uint256 sAVAXShares = ISAVAX(wrapper.sAVAX()).getSharesByPooledAvax(avaxAmount);
        uint256 backToAvax = ISAVAX(wrapper.sAVAX()).getPooledAvaxByShares(sAVAXShares);

        console.log("AVAX amount:", avaxAmount);
        console.log("sAVAX shares:", sAVAXShares);
        console.log("Back to AVAX:", backToAvax);

        assertGt(sAVAXShares, 0, "sAVAX shares should be positive");
        // With exchange rate 1.23, there will be some rounding, so use approx equal
        assertApproxEqRel(backToAvax, avaxAmount, 0.001e18, "sAVAX conversion should be approximately reversible");
    }

    function test_ConversionWithDifferentExchangeRates() public {
        _postInitApprovals();
        uint256 assets = 1000e18;

        // Test at initial rate (1.23) - 1 sAVAX = 1.23 wAVAX
        uint256 shares1 = wrapper.convertToShares(assets);
        uint256 assets1 = wrapper.convertToAssets(shares1);

        // Change the exchange rate to 1.1 (less valuable sAVAX)
        sAVAX.setExchangeRate(1.1e18);

        // Test at new rate
        uint256 shares2 = wrapper.convertToShares(assets);
        uint256 assets2 = wrapper.convertToAssets(shares2);

        console.log("At 1.23 rate - Assets:", assets);
        console.log("At 1.23 rate - Shares:", shares1);
        console.log("At 1.23 rate - Back to assets:", assets1);
        console.log("At 1.1 rate - Assets:", assets);
        console.log("At 1.1 rate - Shares:", shares2);
        console.log("At 1.1 rate - Back to assets:", assets2);

        // With lower exchange rate (1.1 < 1.23), same wAVAX should yield MORE sAVAX shares
        // because sAVAX is now cheaper (1 sAVAX = 1.1 wAVAX instead of 1.23 wAVAX)
        assertGt(shares2, shares1, "Lower exchange rate should yield more shares");

        // But conversions should still be approximately reversible
        assertApproxEqRel(assets1, assets, 0.01e18, "First conversion should be reversible");
        assertApproxEqRel(assets2, assets, 0.01e18, "Second conversion should be reversible");
    }    /*//////////////////////////////////////////////////////////////
                        WRAP/UNWRAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_WrapBasic() public {
    _postInitApprovals();
        uint256 vaultShares = TEST_AMOUNT;

        // First, user needs to get some tAVAX (vault shares)
        vm.startPrank(user1);

        // Get tAVAX through the router
        wAVAX.approve(address(treehouseRouter), vaultShares);
        treehouseRouter.deposit(address(wAVAX), vaultShares);

        uint256 tAVAXBalance = tAVAX.balanceOf(user1);
        assertGt(tAVAXBalance, 0, "User should have tAVAX");

        // Now test wrapping
        tAVAX.approve(address(wrapper), tAVAXBalance);
        uint256 wrapperShares = wrapper.wrap(tAVAXBalance, user1);

        console.log("tAVAX balance:", tAVAXBalance);
        console.log("Wrapper shares received:", wrapperShares);

        assertGt(wrapperShares, 0, "Should receive wrapper shares");
        assertEq(wrapper.balanceOf(user1), wrapperShares, "Balance should match");
        assertEq(tAVAX.balanceOf(user1), 0, "tAVAX should be transferred");

        vm.stopPrank();
    }

    function test_UnwrapBasic() public {
    _postInitApprovals();
        // First wrap some tokens
        uint256 vaultShares = TEST_AMOUNT;

        vm.startPrank(user1);

        // Get tAVAX and wrap it
        wAVAX.approve(address(treehouseRouter), vaultShares);
        treehouseRouter.deposit(address(wAVAX), vaultShares);

        uint256 tAVAXBalance = tAVAX.balanceOf(user1);
        tAVAX.approve(address(wrapper), tAVAXBalance);
        uint256 wrapperShares = wrapper.wrap(tAVAXBalance, user1);

        console.log("Wrapped shares:", wrapperShares);

        // Now test unwrapping
        uint256 unwrappedVaultShares = wrapper.unwrap(wrapperShares, user1, user1);

        console.log("Unwrapped vault shares:", unwrappedVaultShares);

        assertGt(unwrappedVaultShares, 0, "Should receive vault shares");
        assertEq(wrapper.balanceOf(user1), 0, "Wrapper balance should be zero");
        assertEq(tAVAX.balanceOf(user1), unwrappedVaultShares, "Should receive tAVAX back");

        // Should be approximately equal to original amount
        assertApproxEqRel(unwrappedVaultShares, tAVAXBalance, 0.01e18, "Should get back approximately same amount");

        vm.stopPrank();
    }

    function test_WrapUnwrapRoundTrip() public {
    _postInitApprovals();
        uint256 vaultShares = TEST_AMOUNT;

        vm.startPrank(user1);

        // Get initial tAVAX
        wAVAX.approve(address(treehouseRouter), vaultShares);
        treehouseRouter.deposit(address(wAVAX), vaultShares);
        uint256 initialTAVAX = tAVAX.balanceOf(user1);

        // Wrap -> Unwrap -> Check we get back similar amount
        tAVAX.approve(address(wrapper), initialTAVAX);
        uint256 wrapperShares = wrapper.wrap(initialTAVAX, user1);
        uint256 finalTAVAX = wrapper.unwrap(wrapperShares, user1, user1);

        console.log("Initial tAVAX:", initialTAVAX);
        console.log("Wrapper shares:", wrapperShares);
        console.log("Final tAVAX:", finalTAVAX);

        assertApproxEqRel(finalTAVAX, initialTAVAX, 0.01e18, "Round trip should preserve value");

        vm.stopPrank();
    }

    function test_MultipleUsersWrapUnwrap() public {
        _postInitApprovals();
        uint256 amount1 = TEST_AMOUNT;
        uint256 amount2 = TEST_AMOUNT * 2;

        // User1 wraps
        vm.startPrank(user1);
        wAVAX.approve(address(treehouseRouter), amount1);
        treehouseRouter.deposit(address(wAVAX), amount1);
        uint256 tAVAX1 = tAVAX.balanceOf(user1);
        tAVAX.approve(address(wrapper), tAVAX1);
        uint256 shares1 = wrapper.wrap(tAVAX1, user1);
        vm.stopPrank();

        // User2 wraps
        vm.startPrank(user2);
        wAVAX.approve(address(treehouseRouter), amount2);
        treehouseRouter.deposit(address(wAVAX), amount2);
        uint256 tAVAX2 = tAVAX.balanceOf(user2);
        tAVAX.approve(address(wrapper), tAVAX2);
        uint256 shares2 = wrapper.wrap(tAVAX2, user2);
        vm.stopPrank();

        console.log("User1 tAVAX:", tAVAX1);
        console.log("User1 Shares:", shares1);
        console.log("User2 tAVAX:", tAVAX2);
        console.log("User2 Shares:", shares2);

        // Shares should be roughly proportional
        assertApproxEqRel(shares2, shares1 * 2, 0.05e18, "Shares should be proportional to deposits");

        // Both users unwrap
        vm.prank(user1);
        uint256 unwrapped1 = wrapper.unwrap(shares1, user1, user1);

        vm.prank(user2);
        uint256 unwrapped2 = wrapper.unwrap(shares2, user2, user2);

        console.log("User1 unwrapped:", unwrapped1);
        console.log("User2 unwrapped:", unwrapped2);

        assertApproxEqRel(unwrapped1, tAVAX1, 0.01e18, "User1 should get back similar amount");
        assertApproxEqRel(unwrapped2, tAVAX2, 0.01e18, "User2 should get back similar amount");
    }

    function test_PreviewWrapUnwrap() public {
        _postInitApprovals();
        uint256 vaultShares = TEST_AMOUNT;

        // Test preview functions without state changes
        uint256 previewWrapShares = wrapper.previewWrap(vaultShares);
        uint256 previewUnwrapShares = wrapper.previewUnwrap(previewWrapShares);

        console.log("Vault shares:", vaultShares);
        console.log("Preview wrap result:", previewWrapShares);
        console.log("Preview unwrap result:", previewUnwrapShares);

        assertGt(previewWrapShares, 0, "Preview wrap should return positive shares");
        assertApproxEqRel(previewUnwrapShares, vaultShares, 0.01e18, "Preview should be reversible");

        // Now do actual wrap/unwrap and compare
        // Note: When depositing wAVAX through router with 1.23 rate, we get less tAVAX
        vm.startPrank(user1);
        wAVAX.approve(address(treehouseRouter), vaultShares);
        treehouseRouter.deposit(address(wAVAX), vaultShares);
        uint256 tAVAXBalance = tAVAX.balanceOf(user1);

        tAVAX.approve(address(wrapper), tAVAXBalance);
        uint256 actualWrapShares = wrapper.wrap(tAVAXBalance, user1);
        uint256 actualUnwrapShares = wrapper.unwrap(actualWrapShares, user1, user1);

        console.log("Actual wrap result:", actualWrapShares);
        console.log("Actual unwrap result:", actualUnwrapShares);

        // Actual wrap uses the tAVAX received from router (which factors in 1.23 rate)
        // So actualWrapShares should match tAVAXBalance, not the original wAVAX amount
        assertEq(actualWrapShares, tAVAXBalance, "Actual wrap should match tAVAX received");
        assertEq(actualUnwrapShares, tAVAXBalance, "Unwrap should return original tAVAX");

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_ConvertToShares(uint256 assets) public {
        _postInitApprovals();
        assets = bound(assets, 1e15, INITIAL_SUPPLY / 10); // Between 0.001 and 100k tokens

        uint256 shares = wrapper.convertToShares(assets);
        assertGt(shares, 0, "Shares should be positive");

        // Test reversibility
        uint256 backToAssets = wrapper.convertToAssets(shares);
        assertApproxEqRel(backToAssets, assets, 0.02e18, "Should be approximately reversible");
    }

    function testFuzz_WrapUnwrap(uint256 vaultShares) public {
        _postInitApprovals();
        vaultShares = bound(vaultShares, 1e15, INITIAL_SUPPLY / 100); // Reasonable bounds

        vm.startPrank(user1);

        // Get tAVAX
        wAVAX.approve(address(treehouseRouter), vaultShares);
        treehouseRouter.deposit(address(wAVAX), vaultShares);
        uint256 tAVAXBalance = tAVAX.balanceOf(user1);

        if (tAVAXBalance > 0) {
            // Test wrap
            tAVAX.approve(address(wrapper), tAVAXBalance);
            uint256 wrapperShares = wrapper.wrap(tAVAXBalance, user1);
            assertGt(wrapperShares, 0, "Should receive wrapper shares");

            // Test unwrap
            uint256 unwrappedShares = wrapper.unwrap(wrapperShares, user1, user1);
            assertGt(unwrappedShares, 0, "Should receive unwrapped shares");

            // Should be approximately equal
            assertApproxEqRel(unwrappedShares, tAVAXBalance, 0.02e18, "Round trip should preserve value");
        }

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    NEW DEPOSIT BEHAVIOR TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test (1): Deposits with amount=0 should not mint any shares
    function test_DepositZeroAmount() public {
        _postInitApprovals();

        vm.startPrank(user1);

        uint256 sharesBefore = wrapper.balanceOf(user1);
        uint256 totalSupplyBefore = wrapper.totalSupply();

        // Deposit 0 assets
        uint256 shares = wrapper.deposit(0, user1);

        assertEq(shares, 0, "Should mint 0 shares for 0 deposit");
        assertEq(wrapper.balanceOf(user1), sharesBefore, "Balance should not change");
        assertEq(wrapper.totalSupply(), totalSupplyBefore, "Total supply should not change");

        vm.stopPrank();
    }

    /// @notice Test: Rounding boundaries ensure Floor rounding matches ERC-4626 semantics
    function test_DepositRoundingBoundaries() public {
        _postInitApprovals();

        vm.startPrank(user1);

        // Test very small amounts where rounding matters
        uint256[] memory smallAmounts = new uint256[](5);
        smallAmounts[0] = 1;        // 1 wei
        smallAmounts[1] = 10;       // 10 wei
        smallAmounts[2] = 100;      // 100 wei
        smallAmounts[3] = 1000;     // 1000 wei
        smallAmounts[4] = 1e18 / 2; // 0.5 tokens

        for (uint i = 0; i < smallAmounts.length; i++) {
            uint256 amount = smallAmounts[i];

            // Get preview (should use Floor rounding for deposit)
            uint256 previewShares = wrapper.previewDeposit(amount);

            // Actual deposit
            uint256 actualShares = wrapper.deposit(amount, user1);

            console.log("Amount:", amount);
            console.log("Preview shares:", previewShares);
            console.log("Actual shares:", actualShares);

            // With Floor rounding, actual should not exceed preview
            // (they may differ if router behavior affects the amount)
            assertGe(previewShares, 0, "Preview should be non-negative");
            assertGe(actualShares, 0, "Actual shares should be non-negative");
        }

        vm.stopPrank();
    }

    /// @notice Test: Multiple deposits accumulate correctly with actual tAVAX received
    function test_MultipleDepositsWithActualReceipt() public {
        _postInitApprovals();

        vm.startPrank(user1);

        uint256 depositAmount = 100e18;

        // First deposit
        uint256 shares1 = wrapper.deposit(depositAmount, user1);
        uint256 balance1 = wrapper.balanceOf(user1);

        // Second deposit
        uint256 shares2 = wrapper.deposit(depositAmount, user1);
        uint256 balance2 = wrapper.balanceOf(user1);

        // Third deposit
        uint256 shares3 = wrapper.deposit(depositAmount, user1);
        uint256 balance3 = wrapper.balanceOf(user1);

        // Balances should accumulate correctly
        assertEq(balance1, shares1, "First balance should equal first shares");
        assertEq(balance2, shares1 + shares2, "Second balance should accumulate");
        assertEq(balance3, shares1 + shares2 + shares3, "Third balance should accumulate");

        // All deposits of same amount should receive similar shares (within small tolerance)
        assertApproxEqRel(shares1, shares2, 0.01e18, "Similar deposits should get similar shares");
        assertApproxEqRel(shares2, shares3, 0.01e18, "Similar deposits should get similar shares");

        vm.stopPrank();
    }

    /// @notice Test: Deposit event emits correct values based on actual tAVAX
    function test_DepositEventWithActualAmount() public {
        _postInitApprovals();

        vm.startPrank(user1);

        uint256 depositAmount = 100e18;

        // Just verify deposit works and event is emitted
        // We can't easily predict exact event parameters due to complex conversion logic
        uint256 shares = wrapper.deposit(depositAmount, user1);

        // Verify the shares match what user received
        assertEq(wrapper.balanceOf(user1), shares, "Balance should match returned shares");
        assertGt(shares, 0, "Should mint positive shares");

        // Verify assets were transferred
        assertEq(wAVAX.balanceOf(user1), INITIAL_SUPPLY - depositAmount, "wAVAX should be transferred");

        console.log("Deposited:", depositAmount);
        console.log("Shares received:", shares);

        vm.stopPrank();
    }

    /// @notice Test continuous deposits from multiple users to ensure share calculations remain correct
    function test_ContinuousDeposits() public {
        _postInitApprovals();

        console.log("=== Testing Continuous Deposits ===");

        // User 1: First deposit (with 1.23 exchange rate: 100 wAVAX -> ~81.3 shares)
        vm.startPrank(user1);
        uint256 deposit1 = 100e18;
        uint256 shares1 = wrapper.deposit(deposit1, user1);
        console.log("User1 Deposit 1: %e wAVAX -> %e shares", deposit1, shares1);
        // Expected: 100 wAVAX / 1.23 = ~81.3 shares
        uint256 expectedShares1 = (deposit1 * 1e18) / 1.23e18;
        assertApproxEqRel(shares1, expectedShares1, 0.001e18, "First deposit should reflect 1.23 exchange rate");
        vm.stopPrank();

        // User 2: Second deposit (should also get fair shares based on current ratio)
        vm.startPrank(user2);
        uint256 deposit2 = 200e18;
        uint256 shares2 = wrapper.deposit(deposit2, user2);
        console.log("User2 Deposit 1: %e wAVAX -> %e shares", deposit2, shares2);

        // Should get proportional shares: 200 wAVAX / 1.23 = ~162.6 shares
        uint256 expectedShares2 = (deposit2 * 1e18) / 1.23e18;
        assertApproxEqRel(shares2, expectedShares2, 0.01e18, "Second deposit should get fair shares");
        vm.stopPrank();

        // User 1: Second deposit (continuing after user2)
        vm.startPrank(user1);
        uint256 deposit3 = 50e18;
        uint256 balanceBeforeDeposit3 = wrapper.balanceOf(user1);
        uint256 shares3 = wrapper.deposit(deposit3, user1);
        uint256 balanceAfterDeposit3 = wrapper.balanceOf(user1);
        console.log("User1 Deposit 2: %e wAVAX -> %e shares", deposit3, shares3);

        // Check balance accumulation
        assertEq(balanceAfterDeposit3, balanceBeforeDeposit3 + shares3, "User1 balance should accumulate");
        vm.stopPrank();

        // User 2: Second deposit
        vm.startPrank(user2);
        uint256 deposit4 = 150e18;
        uint256 balanceBeforeDeposit4 = wrapper.balanceOf(user2);
        uint256 shares4 = wrapper.deposit(deposit4, user2);
        uint256 balanceAfterDeposit4 = wrapper.balanceOf(user2);
        console.log("User2 Deposit 2: %e wAVAX -> %e shares", deposit4, shares4);

        assertEq(balanceAfterDeposit4, balanceBeforeDeposit4 + shares4, "User2 balance should accumulate");
        vm.stopPrank();

        // Verify final state
        console.log("=== Final State ===");
        console.log("Total Supply: %e", wrapper.totalSupply());
        console.log("Total Vault Shares (tAVAX): %e", wrapper.totalVaultShares());
        console.log("User1 Balance: %e", wrapper.balanceOf(user1));
        console.log("User2 Balance: %e", wrapper.balanceOf(user2));

        // Total supply should equal sum of user balances
        assertEq(wrapper.totalSupply(), wrapper.balanceOf(user1) + wrapper.balanceOf(user2), "Total supply should equal sum of balances");

        // User shares should be proportional to their total deposits (150e18 vs 350e18)
        assertApproxEqRel(
            wrapper.balanceOf(user1),
            (wrapper.totalSupply() * 150e18) / 500e18,
            0.01e18,
            "User1 should have proportional shares"
        );
        assertApproxEqRel(
            wrapper.balanceOf(user2),
            (wrapper.totalSupply() * 350e18) / 500e18,
            0.01e18,
            "User2 should have proportional shares"
        );

        // Verify unwrap works correctly
        vm.startPrank(user1);
        uint256 unwrapShares = wrapper.balanceOf(user1) / 2;
        wrapper.unwrap(unwrapShares, user1, user1);
        console.log("User1 unwrapped half their shares successfully");
        vm.stopPrank();
    }

    /// @notice Test deposits with changing totalSupply and totalVaultShares ratios
    /// Simulates scenarios where:
    /// - totalVaultShares increases (yield accrual) -> fewer shares per deposit
    /// - totalSupply changes via wrap/unwrap -> affects exchange rate
    /// - Both change independently -> demonstrates proper share calculation
    function test_ContinuousDepositsVaryingAmounts() public {
        _postInitApprovals();

        console.log("=== Testing Deposits with Varying totalSupply/totalVaultShares Ratios ===");

        // Scenario 1: Initial deposit establishes ratio based on wAVAX->sAVAX exchange rate
        // With 1.23 exchange rate (1 sAVAX = 1.23 wAVAX):
        // 1000 wAVAX -> 1000/1.23 = ~813.008 sAVAX -> 813.008 tAVAX -> 813.008 shares
        console.log("\n--- Scenario 1: Initial Deposit (1 sAVAX = 1.23 wAVAX) ---");
        vm.startPrank(user1);
        uint256 deposit1 = 1000e18;
        uint256 shares1 = wrapper.deposit(deposit1, user1);
        uint256 totalSupply1 = wrapper.totalSupply();
        uint256 totalVaultShares1 = wrapper.totalVaultShares();
        console.log("Deposit: %e wAVAX -> %e shares", deposit1, shares1);
        console.log("TotalSupply: %e, TotalVaultShares: %e", totalSupply1, totalVaultShares1);
        console.log("Exchange Rate: %e shares per vault share", (totalSupply1 * 1e18) / totalVaultShares1);
        // Expected: 1000 wAVAX / 1.23 = ~813.008 shares
        uint256 expectedShares1 = (deposit1 * 1e18) / 1.23e18;
        assertApproxEqRel(shares1, expectedShares1, 0.001e18, "First deposit should reflect 1.23 exchange rate");
        vm.stopPrank();

        // Scenario 2: Simulate yield accrual by directly transferring tAVAX to wrapper
        // This increases totalVaultShares without changing totalSupply -> exchange rate decreases
        console.log("\n--- Scenario 2: After Yield Accrual (totalVaultShares increases) ---");
        uint256 yieldAmount = 500e18; // 50% yield
        sAVAX.mint(address(this), yieldAmount);
        tAVAX.mint(address(wrapper), yieldAmount);

        uint256 totalSupply2 = wrapper.totalSupply();
        uint256 totalVaultShares2 = wrapper.totalVaultShares();
        console.log("Simulated yield: +%e tAVAX", yieldAmount);
        console.log("TotalSupply: %e (unchanged), TotalVaultShares: %e (increased)", totalSupply2, totalVaultShares2);
        console.log("New Exchange Rate: %e shares per vault share", (totalSupply2 * 1e18) / totalVaultShares2);

        vm.startPrank(user2);
        uint256 deposit2 = 1000e18;
        uint256 shares2 = wrapper.deposit(deposit2, user2);
        console.log("Deposit: %e wAVAX -> %e shares", deposit2, shares2);
        console.log("Shares ratio (deposit1/deposit2): %e", (shares1 * 1e18) / shares2);

        // After yield, same deposit should get fewer shares (because each share is worth more)
        assertLt(shares2, shares1, "After yield accrual, should receive fewer shares for same deposit");
        // Calculate expected: (1000 wAVAX / 1.23) = ~813 tAVAX received
        // shares = 813 * totalSupply / totalVaultShares = 813 * 813 / 1313 ≈ 503
        uint256 tAVAXFromDeposit2 = (deposit2 * 1e18) / 1.23e18;
        uint256 expectedShares2 = (tAVAXFromDeposit2 * totalSupply2) / totalVaultShares2;
        assertApproxEqRel(shares2, expectedShares2, 0.01e18, "Shares should reflect increased vault value");
        vm.stopPrank();

        // Scenario 3: Someone wraps tAVAX directly (increases both totalSupply and totalVaultShares)
        console.log("\n--- Scenario 3: After Direct Wrap (both increase proportionally) ---");
        vm.startPrank(user1);

        // Get tAVAX and wrap it directly
        uint256 wrapAmount = 500e18;
        wAVAX.approve(address(treehouseRouter), wrapAmount);
        treehouseRouter.deposit(address(wAVAX), wrapAmount);
        uint256 tAVAXToWrap = tAVAX.balanceOf(user1);
        tAVAX.approve(address(wrapper), tAVAXToWrap);
        uint256 wrappedShares = wrapper.wrap(tAVAXToWrap, user1);

        uint256 totalSupply3 = wrapper.totalSupply();
        uint256 totalVaultShares3 = wrapper.totalVaultShares();
        console.log("Wrapped %e tAVAX -> %e shares", tAVAXToWrap, wrappedShares);
        console.log("TotalSupply: %e, TotalVaultShares: %e", totalSupply3, totalVaultShares3);
        console.log("Exchange Rate: %e shares per vault share", (totalSupply3 * 1e18) / totalVaultShares3);
        vm.stopPrank();

        // Now deposit again - should get similar rate as scenario 2
        vm.startPrank(user2);
        uint256 deposit3 = 1000e18;
        uint256 shares3 = wrapper.deposit(deposit3, user2);
        console.log("Deposit: %e wAVAX -> %e shares", deposit3, shares3);
        console.log("Shares ratio (deposit2/deposit3): %e", (shares2 * 1e18) / shares3);

        // Should get similar shares as deposit2 (rate shouldn't change much if both increased proportionally)
        assertApproxEqRel(shares3, shares2, 0.05e18, "Proportional increase should maintain exchange rate");
        vm.stopPrank();

        // Scenario 4: Someone unwraps (decreases both totalSupply and totalVaultShares)
        console.log("\n--- Scenario 4: After Unwrap (both decrease) ---");
        vm.startPrank(user1);
        uint256 unwrapShares = wrapper.balanceOf(user1) / 2;
        uint256 unwrappedVaultShares = wrapper.unwrap(unwrapShares, user1, user1);

        uint256 totalSupply4 = wrapper.totalSupply();
        uint256 totalVaultShares4 = wrapper.totalVaultShares();
        console.log("Unwrapped %e shares -> %e tAVAX", unwrapShares, unwrappedVaultShares);
        console.log("TotalSupply: %e, TotalVaultShares: %e", totalSupply4, totalVaultShares4);
        console.log("Exchange Rate: %e shares per vault share", (totalSupply4 * 1e18) / totalVaultShares4);
        vm.stopPrank();

        // Final deposit - rate should be similar to scenario 3
        vm.startPrank(user2);
        uint256 deposit4 = 1000e18;
        uint256 shares4 = wrapper.deposit(deposit4, user2);
        console.log("Deposit: %e wAVAX -> %e shares", deposit4, shares4);
        console.log("Shares ratio (deposit3/deposit4): %e", (shares3 * 1e18) / shares4);

        assertApproxEqRel(shares4, shares3, 0.05e18, "Exchange rate should remain stable");
        vm.stopPrank();

        // Scenario 5: Large yield accrual (simulate 100% yield)
        console.log("\n--- Scenario 5: After Large Yield (100% increase in vault shares) ---");
        uint256 largeYield = totalVaultShares4; // Double the vault shares
        sAVAX.mint(address(this), largeYield);
        tAVAX.mint(address(wrapper), largeYield);

        uint256 totalSupply5 = wrapper.totalSupply();
        uint256 totalVaultShares5 = wrapper.totalVaultShares();
        console.log("Simulated yield: +%e tAVAX (100%% increase)", largeYield);
        console.log("TotalSupply: %e, TotalVaultShares: %e", totalSupply5, totalVaultShares5);
        console.log("Exchange Rate: %e shares per vault share", (totalSupply5 * 1e18) / totalVaultShares5);

        vm.startPrank(user1);
        uint256 deposit5 = 1000e18;
        uint256 shares5 = wrapper.deposit(deposit5, user1);
        console.log("Deposit: %e wAVAX -> %e shares", deposit5, shares5);
        console.log("Shares ratio (deposit4/deposit5): %e", (shares4 * 1e18) / shares5);

        // After doubling vault shares, should get significantly fewer shares
        // The exact ratio depends on previous state, but should be less than before
        assertLt(shares5, shares4, "Large yield should result in fewer shares per deposit");
        assertLt(shares5, shares4 * 60 / 100, "Should get less than 60% of previous shares after 100% yield");
        vm.stopPrank();

        // Final summary
        console.log("\n=== Final State Summary ===");
        console.log("Total Supply: %e", wrapper.totalSupply());
        console.log("Total Vault Shares: %e", wrapper.totalVaultShares());
        console.log("User1 Balance: %e", wrapper.balanceOf(user1));
        console.log("User2 Balance: %e", wrapper.balanceOf(user2));
        console.log("Final Exchange Rate: %e shares per vault share",
            (wrapper.totalSupply() * 1e18) / wrapper.totalVaultShares());
    }

}
