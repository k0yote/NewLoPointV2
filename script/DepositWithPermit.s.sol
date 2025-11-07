// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {JPYCVault} from "../src/JPYCVault.sol";

/**
 * @title IERC20Permit
 * @notice EIP-2612 permit interface
 */
interface IERC20Permit {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
    function nonces(address owner) external view returns (uint256);
    function name() external view returns (string memory);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title DepositWithPermit
 * @notice Foundry script for depositing JPYC into JPYCVault using EIP-2612 permit
 *
 * Usage:
 *   forge script script/DepositWithPermit.s.sol:DepositWithPermit \
 *     --rpc-url $POLYGON_RPC \
 *     --broadcast \
 *     --private-key $PRIVATE_KEY \
 *     --sig "run(address,address,uint256)" \
 *     $JPYC_ADDRESS $VAULT_ADDRESS $AMOUNT
 *
 * Example:
 *   # Deposit 100,000 JPYC
 *   forge script script/DepositWithPermit.s.sol:DepositWithPermit \
 *     --rpc-url https://polygon-rpc.com \
 *     --broadcast \
 *     --private-key 0x... \
 *     --sig "run(address,address,uint256)" \
 *     0x6AE7Dfc73E0dDE2aa99ac063DcF7e8A63265108c \
 *     0x... \
 *     100000000000000000000000
 */
contract DepositWithPermit is Script {
    /**
     * @notice Main entry point for the script
     * @param jpycAddress JPYC token address
     * @param vaultAddress JPYCVault address
     * @param amount Amount to deposit (in wei, 18 decimals)
     */
    function run(address jpycAddress, address vaultAddress, uint256 amount) public {
        // Get deployer info
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deposit JPYC to Vault with Permit ===");
        console.log("Operator:", deployer);
        console.log("JPYC:", jpycAddress);
        console.log("Vault:", vaultAddress);
        console.log("Amount:", amount);
        console.log("");

        IERC20Permit jpyc = IERC20Permit(jpycAddress);
        JPYCVault vault = JPYCVault(vaultAddress);

        // Check balance
        uint256 balance = jpyc.balanceOf(deployer);
        console.log("JPYC Balance:", balance);
        require(balance >= amount, "Insufficient JPYC balance");

        // Check operator role
        bytes32 operatorRole = vault.OPERATOR_ROLE();
        require(vault.hasRole(operatorRole, deployer), "Not an operator");
        console.log("Operator role: OK");
        console.log("");

        // Permit parameters
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = jpyc.nonces(deployer);

        console.log("Creating permit signature...");
        console.log("Nonce:", nonce);
        console.log("Deadline:", deadline);

        // Create EIP-712 signature
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, deployer, vaultAddress, amount, nonce, deadline));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jpyc.DOMAIN_SEPARATOR(), structHash));

        // Sign the digest
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerPrivateKey, digest);

        console.log("Signature created:");
        console.log("  v:", v);
        console.log("  r:", vm.toString(r));
        console.log("  s:", vm.toString(s));
        console.log("");

        // Execute depositWithPermit
        vm.startBroadcast(deployerPrivateKey);

        console.log("Depositing with permit...");
        vault.depositWithPermit(amount, deadline, v, r, s);

        vm.stopBroadcast();

        // Verify
        uint256 vaultBalance = vault.balance();
        console.log("");
        console.log("=== Result ===");
        console.log("Vault Balance:", vaultBalance);
        console.log("Total Deposited:", vault.totalDeposited());
        console.log("");
        console.log("Deposit completed successfully!");
    }

    /**
     * @notice Alternative: Run with environment variables (simplified to avoid stack too deep)
     */
    function runFromEnv() external {
        run(vm.envAddress("JPYC_ADDRESS"), vm.envAddress("VAULT_ADDRESS"), vm.envUint("DEPOSIT_AMOUNT"));
    }
}

/**
 * @title TraditionalDeposit
 * @notice Foundry script for traditional approve + deposit method
 *
 * Usage:
 *   forge script script/DepositWithPermit.s.sol:TraditionalDeposit \
 *     --rpc-url $POLYGON_RPC \
 *     --broadcast \
 *     --private-key $PRIVATE_KEY
 */
contract TraditionalDeposit is Script {
    function run() external {
        address jpycAddress = vm.envAddress("JPYC_ADDRESS");
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        uint256 amount = vm.envUint("DEPOSIT_AMOUNT");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Traditional Deposit (approve + deposit) ===");
        console.log("Operator:", deployer);
        console.log("JPYC:", jpycAddress);
        console.log("Vault:", vaultAddress);
        console.log("Amount:", amount);
        console.log("");

        IERC20Permit jpyc = IERC20Permit(jpycAddress);
        JPYCVault vault = JPYCVault(vaultAddress);

        // Check balance
        uint256 balance = jpyc.balanceOf(deployer);
        console.log("JPYC Balance:", balance);
        require(balance >= amount, "Insufficient JPYC balance");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Approve
        console.log("[1/2] Approving...");
        (bool successApprove,) =
            jpycAddress.call(abi.encodeWithSignature("approve(address,uint256)", vaultAddress, amount));
        require(successApprove, "Approve failed");
        console.log("Approved");
        console.log("");

        // Step 2: Deposit
        console.log("[2/2] Depositing...");
        vault.deposit(amount);
        console.log("Deposited");

        vm.stopBroadcast();

        // Verify
        uint256 vaultBalance = vault.balance();
        console.log("");
        console.log("=== Result ===");
        console.log("Vault Balance:", vaultBalance);
        console.log("");
        console.log("Deposit completed successfully!");
    }
}
