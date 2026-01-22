// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ProofwellStakingV2} from "../src/ProofwellStakingV2.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deploy MockUSDC + ProofwellStakingV2 for testnet testing
contract DeployWithMockUSDCScript is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Use deployer as treasury and charity for testnet
        address treasury = deployer;
        address charity = deployer;

        console.log("=== Deploying Proofwell with MockUSDC ===");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy MockUSDC
        MockUSDC mockUsdc = new MockUSDC();
        console.log("MockUSDC deployed to:", address(mockUsdc));

        // 2. Mint initial USDC to deployer for testing
        mockUsdc.mint(deployer, 10000 * 10 ** 6); // 10,000 USDC
        console.log("Minted 10,000 USDC to deployer");

        // 3. Deploy V2 implementation
        ProofwellStakingV2 implementation = new ProofwellStakingV2();
        console.log("V2 Implementation deployed to:", address(implementation));

        // 4. Deploy proxy with initialization
        bytes memory initData = abi.encodeCall(
            ProofwellStakingV2.initialize,
            (treasury, charity, address(mockUsdc))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log("V2 Proxy deployed to:", address(proxy));

        vm.stopBroadcast();

        // Verify deployment
        ProofwellStakingV2 staking = ProofwellStakingV2(payable(address(proxy)));
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("MockUSDC:        ", address(mockUsdc));
        console.log("V2 Proxy:        ", address(proxy));
        console.log("V2 Implementation:", address(implementation));
        console.log("");
        console.log("=== Contract Config (for iOS) ===");
        console.log("contractAddress: ", address(proxy));
        console.log("usdcAddress:     ", address(mockUsdc));
        console.log("");
        console.log("=== Verification ===");
        console.log("Version:", staking.version());
        console.log("Owner:  ", staking.owner());
        console.log("USDC:   ", address(staking.usdc()));
    }
}
