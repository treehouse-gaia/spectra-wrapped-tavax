// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {SpectraWrappedtAVAX} from "../src/Treehouse/SpectraWrappedtAVAX.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/**
 * @title DeploySpectraWrappedtAVAX
 * @notice Deployment script for SpectraWrappedtAVAX using TransparentUpgradeableProxy
 * @dev This script deploys:
 *   1. Implementation contract (SpectraWrappedtAVAX)
 *   2. TransparentUpgradeableProxy (automatically creates ProxyAdmin and initializes)
 *
 * The TransparentUpgradeableProxy constructor automatically creates a ProxyAdmin contract
 * with the deployer as the initial owner. This ProxyAdmin manages all upgrade operations.
 *
 * Usage:
 *   forge script script/DeploySpectraWrappedtAVAX.s.sol:DeploySpectraWrappedtAVAX --rpc-url <RPC_URL> --broadcast --verify
 *
 * Environment variables required:
 *   - PRIVATE_KEY: Private key for deployment (or use --account with foundry keystore)
 *
 * Addresses are hardcoded for Avalanche mainnet. For other networks, modify setUp() function.
 */
contract DeploySpectraWrappedtAVAX is Script {
    // Deployment addresses will be read from environment variables
    address public wAVAX;
    address public sAVAX;
    address public tAVAX;
    address public treehouseRouter;
    address public initialAuthority;

    // Deployed contract addresses
    SpectraWrappedtAVAX public implementation;
    TransparentUpgradeableProxy public proxy;
    SpectraWrappedtAVAX public wrappedTAVAX;
    address public multisigAddr;
    address public proxyAdminAddress;

    function setUp() public {
        // AVALANCHE MAINNET ADDRESSES (C-Chain: 43114)
        // These are official, verified protocol addresses - DO NOT MODIFY
        // For testnet deployments, create a separate script with Fuji addresses

        wAVAX = address(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);  // Official Wrapped AVAX
        sAVAX = address(0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE);  // Benqi Liquid Staked AVAX
        tAVAX = address(0x14A84F1a61cCd7D1BE596A6cc11FE33A36Bc1646);  // TreeHouse tAVAX Vault
        treehouseRouter = address(0x5f4D2e6C118b5E3c74f0b61De40f627Ca9873d6e);  // TreeHouse Router
        initialAuthority = address(0x4973b53b300d64ab72147EFF8C9d962f6b1dA02e);  // Spectra DAO Access Manager
        // Reference: https://dev.spectra.finance/technical-reference/deployed-contracts

        // Validate addresses are not zero
        require(wAVAX != address(0), "wAVAX address cannot be zero");
        require(sAVAX != address(0), "sAVAX address cannot be zero");
        require(tAVAX != address(0), "tAVAX address cannot be zero");
        require(treehouseRouter != address(0), "TreehouseRouter address cannot be zero");
        require(initialAuthority != address(0), "Initial authority address cannot be zero");
    }

    function run() external {
        // Start broadcasting transactions
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        multisigAddr = address(0xC807aFFBf0156d816de6E707C3Bb10A24eE0f9AB);
        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying SpectraWrappedtAVAX...");
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("");
        console.log("Configuration:");
        console.log("  wAVAX:", wAVAX);
        console.log("  sAVAX:", sAVAX);
        console.log("  tAVAX:", tAVAX);
        console.log("  TreehouseRouter:", treehouseRouter);
        console.log("  Initial Authority:", initialAuthority);
        console.log("");

        // Step 1: Deploy implementation contract
        console.log("Step 1: Deploying implementation contract...");
        implementation = new SpectraWrappedtAVAX(wAVAX, sAVAX, treehouseRouter);
        console.log("Implementation deployed at:", address(implementation));

        // Step 2: Prepare initialization data
        console.log("Step 2: Preparing initialization data...");
        bytes memory initData = abi.encodeCall(
            SpectraWrappedtAVAX.initialize,
            (
                wAVAX,
                sAVAX,
                tAVAX,
                treehouseRouter,
                initialAuthority
            )
        );

        // Step 3: Deploy TransparentUpgradeableProxy
        // Note: This will automatically create a ProxyAdmin with deployer as owner
        console.log("Step 3: Deploying TransparentUpgradeableProxy...");
        proxy = new TransparentUpgradeableProxy(
            address(implementation),
            multisigAddr,  // initialOwner of the ProxyAdmin (that will be created)
            initData
        );
        console.log("Proxy deployed at:", address(proxy));

        // Step 4: Cast proxy to implementation interface
        console.log("Step 4: Cast proxy to implementation interface");
        wrappedTAVAX = SpectraWrappedtAVAX(address(proxy));

        // Step 5: Verify deployment
        console.log("");
        console.log("Step 5: Verifying deployment...");
        console.log("  Wrapper asset (wAVAX):", wrappedTAVAX.asset());
        console.log("  Wrapper vaultShare (tAVAX):", wrappedTAVAX.vaultShare());
        console.log("  Wrapper name:", wrappedTAVAX.name());
        console.log("  Wrapper symbol:", wrappedTAVAX.symbol());
        console.log("  Total supply:", wrappedTAVAX.totalSupply());

        require(wrappedTAVAX.asset() == wAVAX, "Asset mismatch");
        require(wrappedTAVAX.vaultShare() == tAVAX, "VaultShare mismatch");
        require(wrappedTAVAX.wAVAX() == wAVAX, "wAVAX mismatch");
        require(wrappedTAVAX.sAVAX() == sAVAX, "sAVAX mismatch");
        require(wrappedTAVAX.treehouseRouter() == treehouseRouter, "TreehouseRouter mismatch");

        // Verify ProxyAdmin ownership
        _verifyProxyAdmin();

        console.log("");
        console.log("===========================================");
        console.log("Deployment successful!");
        console.log("===========================================");
        console.log("Implementation:", address(implementation));
        console.log("Proxy (SpectraWrappedtAVAX):", address(proxy));
        console.log("ProxyAdmin:", proxyAdminAddress);
        console.log("ProxyAdmin Owner (Multisig):", multisigAddr);
        console.log("===========================================");
        console.log("");
        console.log("IMPORTANT: Save the proxy address for interactions!");
        console.log("Contract address to use:", address(proxy));

        vm.stopBroadcast();

        // Save deployment info to file
        _saveDeployment();
    }

    function _verifyProxyAdmin() internal {
        console.log("");
        console.log("Step 6: Verifying ProxyAdmin ownership...");

        // Get the ProxyAdmin address from the proxy using the EIP-1967 admin storage slot
        // This is cleaner than the raw vm.load() call - using the constant from ERC1967Utils
        proxyAdminAddress = address(uint160(uint256(
            vm.load(address(proxy), ERC1967Utils.ADMIN_SLOT)
        )));

        console.log("  ProxyAdmin address:", proxyAdminAddress);
        console.log("  ProxyAdmin owner:", ProxyAdmin(proxyAdminAddress).owner());
        console.log("  Expected multisig:", multisigAddr);

        require(ProxyAdmin(proxyAdminAddress).owner() == multisigAddr, "ProxyAdmin owner is not multisig");
        console.log("  [OK] ProxyAdmin is owned by multisig");
    }

    function _saveDeployment() internal {
        string memory deploymentInfo = string.concat(
            "# SpectraWrappedtAVAX Deployment\n\n",
            "**Network:** ", vm.toString(block.chainid), "\n",
            "**Block:** ", vm.toString(block.number), "\n",
            "**Timestamp:** ", vm.toString(block.timestamp), "\n\n",
            "## Addresses\n\n",
            "- **Implementation:** ", vm.toString(address(implementation)), "\n",
            "- **Proxy (Main Contract):** ", vm.toString(address(proxy)), "\n",
            "- **ProxyAdmin:** ", vm.toString(proxyAdminAddress), "\n",
            "- **ProxyAdmin Owner (Multisig):** ", vm.toString(multisigAddr), "\n\n",
            "## Configuration\n\n",
            "- **wAVAX:** ", vm.toString(wAVAX), "\n",
            "- **sAVAX:** ", vm.toString(sAVAX), "\n",
            "- **tAVAX:** ", vm.toString(tAVAX), "\n",
            "- **TreehouseRouter:** ", vm.toString(treehouseRouter), "\n",
            "- **Initial Authority:** ", vm.toString(initialAuthority), "\n"
        );

        vm.writeFile("deployments/latest.md", deploymentInfo);
        console.log("Deployment info saved to: deployments/latest.md");
    }
}
