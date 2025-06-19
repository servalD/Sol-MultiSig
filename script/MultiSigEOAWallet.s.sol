// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../lib/forge-std/src/Script.sol";
import "../src/MultiSigEOAWallet.sol";

contract DeployMultiSigEOAWalletLocal is Script {
    function run() external {
        // For local testing with anvil
        vm.startBroadcast();

        address[] memory owners = new address[](3);
        owners[0] = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // anvil account 0
        owners[1] = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // anvil account 1
        owners[2] = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // anvil account 2

        MultiSigEOAWallet wallet = new MultiSigEOAWallet(owners, 2);

        vm.stopBroadcast();

        console.log("MultiSigEOAWallet deployed locally at:", address(wallet));
        console.log("Owners:");
        for (uint i = 0; i < owners.length; i++) {
            console.log("  ", owners[i]);
        }
    }
}
