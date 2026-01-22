// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ProofwellStakingV2} from "../src/ProofwellStakingV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployV2Script is Script {
    // Base Sepolia USDC address
    address constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Use deployer as treasury and charity for testnet (can be updated later)
        address treasury = deployer;
        address charity = deployer;

        console.log("Deployer:", deployer);
        console.log("Treasury:", treasury);
        console.log("Charity:", charity);
        console.log("USDC:", BASE_SEPOLIA_USDC);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy implementation
        ProofwellStakingV2 implementation = new ProofwellStakingV2();
        console.log("Implementation deployed to:", address(implementation));

        // 2. Deploy proxy with initialization
        bytes memory initData = abi.encodeCall(ProofwellStakingV2.initialize, (treasury, charity, BASE_SEPOLIA_USDC));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log("Proxy deployed to:", address(proxy));

        vm.stopBroadcast();

        // Verify deployment via proxy
        ProofwellStakingV2 staking = ProofwellStakingV2(payable(address(proxy)));
        console.log("");
        console.log("Verification:");
        console.log("  Version:", staking.version());
        console.log("  Owner:", staking.owner());
        console.log("  Treasury:", staking.treasury());
        console.log("  Charity:", staking.charity());
        console.log("");
        console.log("Distribution:");
        console.log("  Winners:", staking.winnerPercent(), "%");
        console.log("  Treasury:", staking.treasuryPercent(), "%");
        console.log("  Charity:", staking.charityPercent(), "%");
    }
}
