// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ProofwellStaking} from "../src/ProofwellStaking.sol";

contract DeployScript is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Treasury:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        ProofwellStaking staking = new ProofwellStaking(deployer);

        vm.stopBroadcast();

        console.log("ProofwellStaking deployed to:", address(staking));
    }
}
