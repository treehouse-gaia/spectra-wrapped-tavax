// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {SpectraWrappedtAVAX} from "../src/Treehouse/SpectraWrappedtAVAX.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
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
    IERC20 public immutable tAVAX;

    constructor(address _wAVAX, address _tAVAX) {
        wAVAX = IERC20(_wAVAX);
        tAVAX = IERC20(_tAVAX);
    }

    function deposit(address token, uint256 amount) external {
        require(token == address(wAVAX), "Only wAVAX supported");
        wAVAX.transferFrom(msg.sender, address(this), amount);
        // Give back tAVAX 1:1 for simplicity
        tAVAX.transfer(msg.sender, amount);
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

        // Deploy mock router
        treehouseRouter = new MockTreehouseRouter(address(wAVAX), address(tAVAX));

        // Setup initial balances
        wAVAX.mint(user1, INITIAL_SUPPLY);
        wAVAX.mint(user2, INITIAL_SUPPLY);
        wAVAX.mint(address(treehouseRouter), INITIAL_SUPPLY);

        // Give router some tAVAX to distribute
        sAVAX.mint(address(treehouseRouter), INITIAL_SUPPLY);
        tAVAX.mint(address(treehouseRouter), INITIAL_SUPPLY);

        // Deploy implementation (logic) contract (constructor disables initializers)
        implementation = new SpectraWrappedtAVAX();

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
        assertEq(backToAvax, avaxAmount, "sAVAX conversion should be reversible");
    }

    function test_ConversionWithDifferentExchangeRates() public {
    _postInitApprovals();
        uint256 assets = TEST_AMOUNT;

        // Test at 1:1 rate
        uint256 shares1 = wrapper.convertToShares(assets);
        uint256 assets1 = wrapper.convertToAssets(shares1);

        // Change sAVAX exchange rate to simulate yield (10% increase)
        sAVAX.setExchangeRate(1.1e18);

        // Test at new rate
        uint256 shares2 = wrapper.convertToShares(assets);
        uint256 assets2 = wrapper.convertToAssets(shares2);

        console.log("At 1:1 rate - Assets:", assets);
        console.log("At 1:1 rate - Shares:", shares1);
        console.log("At 1:1 rate - Back to assets:", assets1);
        console.log("At 1.1:1 rate - Assets:", assets);
        console.log("At 1.1:1 rate - Shares:", shares2);
        console.log("At 1.1:1 rate - Back to assets:", assets2);

        // With higher exchange rate, same assets should yield fewer shares
        assertLt(shares2, shares1, "Higher exchange rate should yield fewer shares");

        // But conversions should still be approximately reversible
        assertApproxEqRel(assets1, assets, 0.01e18, "First conversion should be reversible");
        assertApproxEqRel(assets2, assets, 0.01e18, "Second conversion should be reversible");
    }

    /*//////////////////////////////////////////////////////////////
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
        vm.startPrank(user1);
        wAVAX.approve(address(treehouseRouter), vaultShares);
        treehouseRouter.deposit(address(wAVAX), vaultShares);
        uint256 tAVAXBalance = tAVAX.balanceOf(user1);

        tAVAX.approve(address(wrapper), tAVAXBalance);
        uint256 actualWrapShares = wrapper.wrap(tAVAXBalance, user1);
        uint256 actualUnwrapShares = wrapper.unwrap(actualWrapShares, user1, user1);

        console.log("Actual wrap result:", actualWrapShares);
        console.log("Actual unwrap result:", actualUnwrapShares);

        // Preview should match actual (approximately)
        assertApproxEqRel(actualWrapShares, previewWrapShares, 0.01e18, "Actual wrap should match preview");

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
}
