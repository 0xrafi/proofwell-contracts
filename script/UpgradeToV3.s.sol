// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ProofwellStakingV2} from "../src/ProofwellStakingV2.sol";
import {ProofwellStakingV3} from "../src/ProofwellStakingV3.sol";

contract UpgradeToV3Script is Script {
    // Base Sepolia proxy address
    address constant PROXY = 0xF45DBE98b014cc8564291B052e8D98Bbe9C7651d;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Verify current state
        ProofwellStakingV2 current = ProofwellStakingV2(payable(PROXY));
        console.log("Current version:", current.version());
        console.log("Owner:", current.owner());

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy new V3 implementation
        ProofwellStakingV3 v3Impl = new ProofwellStakingV3();
        console.log("V3 implementation deployed to:", address(v3Impl));

        // 2. Upgrade proxy + initialize V3
        current.upgradeToAndCall(address(v3Impl), abi.encodeCall(ProofwellStakingV3.initializeV3, ()));

        vm.stopBroadcast();

        // 3. Verify
        ProofwellStakingV3 upgraded = ProofwellStakingV3(payable(PROXY));
        console.log("");
        console.log("Upgrade verification:");
        console.log("  Version:", upgraded.version());
        console.log("  Owner:", upgraded.owner());
        console.log("  Treasury:", upgraded.treasury());
        console.log("  MAX_ACTIVE_STAKES:", upgraded.MAX_ACTIVE_STAKES());

        require(keccak256(bytes(upgraded.version())) == keccak256(bytes("3.0.0")), "Version mismatch after upgrade");
        console.log("");
        console.log("Upgrade to V3 successful!");
    }
}
