// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {NLPMinterBurner} from "../src/NLPMinterBurner.sol";
import {NLPCCIPAdapter} from "../src/NLPCCIPAdapter.sol";
import {NLPCCIPJPYCReceiver} from "../src/NLPCCIPJPYCReceiver.sol";
import {JPYCVault} from "../src/JPYCVault.sol";

/**
 * @title DeployCCIP
 * @notice Deployment script for Chainlink CCIP contracts
 * @dev Deploys NLP bridge contracts using Chainlink CCIP
 *
 * Usage:
 * 1. Deploy on Soneium:
 *    forge script script/DeployCCIP.s.sol:DeploySoneiumCCIP --rpc-url $SONEIUM_RPC --broadcast
 *
 * 2. Deploy on Polygon:
 *    forge script script/DeployCCIP.s.sol:DeployPolygonCCIP --rpc-url $POLYGON_RPC --broadcast
 *
 * 3. Configure chains:
 *    forge script script/DeployCCIP.s.sol:ConfigureCCIPChains --rpc-url $SONEIUM_RPC --broadcast
 */
contract DeploySoneiumCCIP is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address nlpToken = vm.envAddress("NLP_TOKEN_ADDRESS");
        address ccipRouter = vm.envAddress("SONEIUM_CCIP_ROUTER");
        address linkToken = vm.envAddress("SONEIUM_LINK_TOKEN");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying CCIP contracts on Soneium...");
        console.log("Deployer:", deployer);
        console.log("NLP Token:", nlpToken);
        console.log("CCIP Router:", ccipRouter);
        console.log("LINK Token:", linkToken);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy NLPMinterBurner (if not already deployed)
        console.log("\n1. Deploying NLPMinterBurner...");
        NLPMinterBurner minterBurner = new NLPMinterBurner(nlpToken, deployer);
        console.log("NLPMinterBurner deployed at:", address(minterBurner));

        // 2. Deploy NLPCCIPAdapter
        console.log("\n2. Deploying NLPCCIPAdapter...");
        NLPCCIPAdapter adapter = new NLPCCIPAdapter(
            nlpToken,
            address(minterBurner),
            ccipRouter,
            linkToken,
            deployer
        );
        console.log("NLPCCIPAdapter deployed at:", address(adapter));

        // 3. Authorize adapter in MinterBurner
        console.log("\n3. Authorizing adapter in MinterBurner...");
        minterBurner.setOperator(address(adapter), true);
        console.log("Adapter authorized");

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("NLPMinterBurner:", address(minterBurner));
        console.log("NLPCCIPAdapter:", address(adapter));
        console.log("\nNext steps:");
        console.log("1. Grant MINTER_ROLE to NLPMinterBurner on NLP token");
        console.log("2. Fund adapter with LINK for fees (or use native fees)");
        console.log("3. Deploy on destination chain (Polygon)");
        console.log("4. Configure destination on adapter");
    }
}

contract DeployPolygonCCIP is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address jpycToken = vm.envAddress("JPYC_POLYGON_ADDRESS");
        address ccipRouter = vm.envAddress("POLYGON_CCIP_ROUTER");
        address linkToken = vm.envAddress("POLYGON_LINK_TOKEN");
        address deployer = vm.addr(deployerPrivateKey);
        uint256 vaultMinBalance = vm.envOr("VAULT_MIN_BALANCE", uint256(100000 * 10**18)); // 100k JPYC default

        console.log("Deploying CCIP contracts on Polygon...");
        console.log("Deployer:", deployer);
        console.log("JPYC Token:", jpycToken);
        console.log("CCIP Router:", ccipRouter);
        console.log("LINK Token:", linkToken);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy JPYCVault (if not already deployed)
        console.log("\n1. Deploying JPYCVault...");
        JPYCVault vault = new JPYCVault(jpycToken, deployer, vaultMinBalance);
        console.log("JPYCVault deployed at:", address(vault));

        // 2. Deploy NLPCCIPJPYCReceiver
        console.log("\n2. Deploying NLPCCIPJPYCReceiver...");
        NLPCCIPJPYCReceiver receiver = new NLPCCIPJPYCReceiver(
            jpycToken,
            address(vault),
            ccipRouter,
            linkToken,
            deployer
        );
        console.log("NLPCCIPJPYCReceiver deployed at:", address(receiver));

        // 3. Grant EXCHANGE_ROLE to receiver
        console.log("\n3. Granting EXCHANGE_ROLE to receiver...");
        bytes32 EXCHANGE_ROLE = keccak256("EXCHANGE_ROLE");
        vault.grantRole(EXCHANGE_ROLE, address(receiver));
        console.log("EXCHANGE_ROLE granted");

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("JPYCVault:", address(vault));
        console.log("NLPCCIPJPYCReceiver:", address(receiver));
        console.log("\nNext steps:");
        console.log("1. Fund JPYCVault with JPYC");
        console.log("2. Fund receiver with LINK for response messages");
        console.log("3. Configure source chain on receiver");
        console.log("4. Configure destination on Soneium adapter");
    }
}

contract ConfigureCCIPChains is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address adapterAddress = vm.envAddress("NLPCCIP_ADAPTER_ADDRESS");
        address receiverAddress = vm.envAddress("NLPCCIP_RECEIVER_ADDRESS");
        uint64 soneiumChainSelector = uint64(vm.envUint("SONEIUM_CHAIN_SELECTOR"));
        uint64 polygonChainSelector = uint64(vm.envUint("POLYGON_CHAIN_SELECTOR"));

        console.log("Configuring CCIP chains...");
        console.log("Soneium Adapter:", adapterAddress);
        console.log("Polygon Receiver:", receiverAddress);
        console.log("Soneium Chain Selector:", soneiumChainSelector);
        console.log("Polygon Chain Selector:", polygonChainSelector);

        vm.startBroadcast(deployerPrivateKey);

        NLPCCIPAdapter adapter = NLPCCIPAdapter(payable(adapterAddress));

        // Configure destination on Soneium adapter
        console.log("\nConfiguring destination on adapter...");
        adapter.configureDestination(polygonChainSelector, receiverAddress);
        console.log("Destination configured on adapter");

        vm.stopBroadcast();

        console.log("\n=== Configuration Complete ===");
        console.log("Adapter destination set to receiver on Polygon");
        console.log("\nRun on Polygon to complete bi-directional setup:");
        console.log("NLPCCIPJPYCReceiver.configureSourceChain(soneiumChainSelector, adapterAddress)");
        console.log("  soneiumChainSelector:", soneiumChainSelector);
        console.log("  adapterAddress:", adapterAddress);
    }
}
