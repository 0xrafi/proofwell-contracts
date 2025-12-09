// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ProofwellStakingV2} from "../src/ProofwellStakingV2.sol";

contract DeployV2Script is Script {
    // Base Sepolia USDC address
    address constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Use deployer as treasury and charity for testnet (can be updated later)
        address treasury = deployer;
        address charity = deployer;
        address usdc = BASE_SEPOLIA_USDC;

        console.log("Deployer:", deployer);
        console.log("Treasury:", treasury);
        console.log("Charity:", charity);
        console.log("USDC:", usdc);

        vm.startBroadcast(deployerPrivateKey);

        ProofwellStakingV2 staking = new ProofwellStakingV2(treasury, charity, usdc);

        vm.stopBroadcast();

        console.log("ProofwellStakingV2 deployed to:", address(staking));
        console.log("");
        console.log("Distribution:");
        console.log("  Winners:", staking.winnerPercent(), "%");
        console.log("  Treasury:", staking.treasuryPercent(), "%");
        console.log("  Charity:", staking.charityPercent(), "%");
    }
}
