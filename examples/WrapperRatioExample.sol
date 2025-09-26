// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title WrapperRatioExample
 * @dev Demonstrates why the wrapper ratio changes over time
 */
contract WrapperRatioExample {
    
    // Example scenario to show why ratio != 1
    function demonstrateRatioChange() external pure returns (
        uint256 initialRatio,
        uint256 afterYieldRatio,
        uint256 afterLossRatio
    ) {
        // SCENARIO 1: Initial state
        uint256 totalVaultShares1 = 1000e18;  // 1000 tAVAX in vault
        uint256 totalSupply1 = 1000e18;       // 1000 wrapper shares issued
        uint256 offset = 1e12;                // decimals offset
        
        initialRatio = (totalSupply1 + offset) * 1e18 / (totalVaultShares1 + 1);
        // ≈ 1.0 (almost 1:1)
        
        // SCENARIO 2: After yield (tAVAX grows 20%)
        uint256 totalVaultShares2 = 1200e18;  // tAVAX grew to 1200 (20% yield)
        uint256 totalSupply2 = 1000e18;       // wrapper shares unchanged
        
        afterYieldRatio = (totalSupply2 + offset) * 1e18 / (totalVaultShares2 + 1);
        // ≈ 0.833 (each vault share now worth fewer wrapper shares)
        
        // SCENARIO 3: After loss (tAVAX drops 10% from initial)
        uint256 totalVaultShares3 = 900e18;   // tAVAX dropped to 900
        uint256 totalSupply3 = 1000e18;       // wrapper shares unchanged
        
        afterLossRatio = (totalSupply3 + offset) * 1e18 / (totalVaultShares3 + 1);
        // ≈ 1.111 (each vault share now worth more wrapper shares)
    }
    
    // What happens when new user deposits after yield
    function demonstrateNewDeposit() external pure returns (
        uint256 vaultSharesDeposited,
        uint256 wrapperSharesReceived
    ) {
        // Existing state: vault grew 20%
        uint256 totalVaultShares = 1200e18;
        uint256 totalSupply = 1000e18;
        uint256 offset = 1e12;
        
        // New user wants to deposit 100 vault shares
        vaultSharesDeposited = 100e18;
        
        // They should get proportionally fewer wrapper shares
        wrapperSharesReceived = vaultSharesDeposited * 
            (totalSupply + offset) / (totalVaultShares + 1);
        
        // ≈ 83.33 wrapper shares (not 100!)
        // This maintains fairness - they get fewer shares because 
        // each wrapper share now represents more value
    }
}
