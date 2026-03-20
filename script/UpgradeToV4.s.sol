// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ProofwellStakingV3} from "../src/ProofwellStakingV3.sol";
import {ProofwellStakingV4} from "../src/ProofwellStakingV4.sol";

contract UpgradeToV4Script is Script {
    // Base Sepolia proxy address
    address constant PROXY = 0xF45DBE98b014cc8564291B052e8D98Bbe9C7651d;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Verify current state
        ProofwellStakingV3 current = ProofwellStakingV3(payable(PROXY));
        console.log("Current version:", current.version());
        console.log("Owner:", current.owner());

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy new V4 implementation
        ProofwellStakingV4 v4Impl = new ProofwellStakingV4();
        console.log("V4 implementation deployed to:", address(v4Impl));

        // 2. Upgrade proxy + initialize V4
        current.upgradeToAndCall(address(v4Impl), abi.encodeCall(ProofwellStakingV4.initializeV4, ()));

        vm.stopBroadcast();

        // 3. Verify
        ProofwellStakingV4 upgraded = ProofwellStakingV4(payable(PROXY));
        console.log("");
        console.log("Upgrade verification:");
        console.log("  Version:", upgraded.version());
        console.log("  Owner:", upgraded.owner());
        console.log("  Treasury:", upgraded.treasury());
        console.log("  nextPoolId:", upgraded.nextPoolId());

        require(keccak256(bytes(upgraded.version())) == keccak256(bytes("4.0.0")), "Version mismatch after upgrade");
        console.log("");
        console.log("Upgrade to V4 successful!");
    }
}
