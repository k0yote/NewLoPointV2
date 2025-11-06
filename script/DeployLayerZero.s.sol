// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {NLPMinterBurner} from "../src/NLPMinterBurner.sol";
import {NLPOAppAdapter} from "../src/NLPOAppAdapter.sol";
import {NLPOAppJPYCReceiver} from "../src/NLPOAppJPYCReceiver.sol";
import {JPYCVault} from "../src/JPYCVault.sol";

/**
 * @title DeployLayerZero
 * @notice Deployment script for LayerZero OApp contracts
 * @dev Deploys NLP bridge contracts using LayerZero V2
 *
 * Usage:
 * 1. Deploy on Soneium:
 *    forge script script/DeployLayerZero.s.sol:DeploySoneiumLayerZero --rpc-url $SONEIUM_RPC --broadcast
 *
 * 2. Deploy on Polygon (or other destination):
 *    forge script script/DeployLayerZero.s.sol:DeployPolygonLayerZero --rpc-url $POLYGON_RPC --broadcast
 *
 * 3. Configure peers:
 *    forge script script/DeployLayerZero.s.sol:ConfigureLayerZeroPeers --rpc-url $SONEIUM_RPC --broadcast
 */
contract DeploySoneiumLayerZero is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address nlpToken = vm.envAddress("NLP_TOKEN_ADDRESS");
        address lzEndpoint = vm.envAddress("SONEIUM_LZ_ENDPOINT");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying LayerZero contracts on Soneium...");
        console.log("Deployer:", deployer);
        console.log("NLP Token:", nlpToken);
        console.log("LZ Endpoint:", lzEndpoint);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy NLPMinterBurner
        console.log("\n1. Deploying NLPMinterBurner...");
        NLPMinterBurner minterBurner = new NLPMinterBurner(nlpToken, deployer);
        console.log("NLPMinterBurner deployed at:", address(minterBurner));

        // 2. Deploy NLPOAppAdapter
        console.log("\n2. Deploying NLPOAppAdapter...");
        NLPOAppAdapter adapter = new NLPOAppAdapter(
            nlpToken,
            address(minterBurner),
            lzEndpoint,
            deployer
        );
        console.log("NLPOAppAdapter deployed at:", address(adapter));

        // 3. Authorize adapter in MinterBurner
        console.log("\n3. Authorizing adapter in MinterBurner...");
        minterBurner.setOperator(address(adapter), true);
        console.log("Adapter authorized");

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("NLPMinterBurner:", address(minterBurner));
        console.log("NLPOAppAdapter:", address(adapter));
        console.log("\nNext steps:");
        console.log("1. Grant MINTER_ROLE to NLPMinterBurner on NLP token");
        console.log("2. Deploy on destination chain (Polygon)");
        console.log("3. Configure peers on both chains");
    }
}

contract DeployPolygonLayerZero is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address jpycToken = vm.envAddress("JPYC_POLYGON_ADDRESS");
        address lzEndpoint = vm.envAddress("POLYGON_LZ_ENDPOINT");
        address deployer = vm.addr(deployerPrivateKey);
        uint256 vaultMinBalance = vm.envOr("VAULT_MIN_BALANCE", uint256(100000 * 10**18)); // 100k JPYC default

        console.log("Deploying LayerZero contracts on Polygon...");
        console.log("Deployer:", deployer);
        console.log("JPYC Token:", jpycToken);
        console.log("LZ Endpoint:", lzEndpoint);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy JPYCVault
        console.log("\n1. Deploying JPYCVault...");
        JPYCVault vault = new JPYCVault(jpycToken, deployer, vaultMinBalance);
        console.log("JPYCVault deployed at:", address(vault));

        // 2. Deploy NLPOAppJPYCReceiver
        console.log("\n2. Deploying NLPOAppJPYCReceiver...");
        NLPOAppJPYCReceiver receiver = new NLPOAppJPYCReceiver(
            jpycToken,
            address(vault),
            lzEndpoint,
            deployer
        );
        console.log("NLPOAppJPYCReceiver deployed at:", address(receiver));

        // 3. Grant EXCHANGE_ROLE to receiver
        console.log("\n3. Granting EXCHANGE_ROLE to receiver...");
        bytes32 EXCHANGE_ROLE = keccak256("EXCHANGE_ROLE");
        vault.grantRole(EXCHANGE_ROLE, address(receiver));
        console.log("EXCHANGE_ROLE granted");

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("JPYCVault:", address(vault));
        console.log("NLPOAppJPYCReceiver:", address(receiver));
        console.log("\nNext steps:");
        console.log("1. Fund JPYCVault with JPYC");
        console.log("2. Fund receiver with native tokens for response messages");
        console.log("3. Configure peers on both chains");
    }
}

contract ConfigureLayerZeroPeers is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address adapterAddress = vm.envAddress("NLPOAPP_ADAPTER_ADDRESS");
        address receiverAddress = vm.envAddress("NLPOAPP_RECEIVER_ADDRESS");
        uint32 soneiumEid = uint32(vm.envUint("SONEIUM_EID"));
        uint32 polygonEid = uint32(vm.envUint("POLYGON_EID"));

        console.log("Configuring LayerZero peers...");
        console.log("Soneium Adapter:", adapterAddress);
        console.log("Polygon Receiver:", receiverAddress);
        console.log("Soneium EID:", soneiumEid);
        console.log("Polygon EID:", polygonEid);

        vm.startBroadcast(deployerPrivateKey);

        NLPOAppAdapter adapter = NLPOAppAdapter(payable(adapterAddress));

        // Set peer on Soneium -> Polygon
        console.log("\nSetting peer: Soneium -> Polygon");
        bytes32 receiverBytes32 = bytes32(uint256(uint160(receiverAddress)));
        adapter.setPeer(polygonEid, receiverBytes32);
        console.log("Peer set on adapter");

        vm.stopBroadcast();

        console.log("\n=== Configuration Complete ===");
        console.log("Adapter peer set to receiver on Polygon");
        console.log("\nRun the same on Polygon to complete bi-directional setup:");
        console.log("NLPOAppJPYCReceiver.setPeer(soneiumEid, adapterAddress)");
        console.log("  soneiumEid:", soneiumEid);
        console.log("  adapterAddress:", adapterAddress);
    }
}
