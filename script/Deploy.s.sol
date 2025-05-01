// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {HookMiner} from "../test/utils/HookMiner.sol";

import {TWAMM} from "../src/TWAMM.sol";

contract DeployScript is Script {
    address private CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address private POOL_MANAGER;

    address private CONTROLLER_MULTISIG = 0xd3492D595e3039355D363AC9784C9dB96E074b70;
    uint256 private expirationInterval = 30 minutes;

    function setUp() public {
        if (block.chainid == 8453) {
            POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b; // Base
        } else if (block.chainid == 130) {
            POOL_MANAGER = 0x1F98400000000000000000000000000000000004; // Unichain
        } else {
            revert("DeployScript: Unsupported chain");
        }
    }

    function run() public {
        require(POOL_MANAGER != address(0), "DeployScript: POOL_MANAGER not set");

        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(POOL_MANAGER, expirationInterval, CONTROLLER_MULTISIG);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(TWAMM).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.broadcast();
        TWAMM twammHook = new TWAMM{salt: salt}(IPoolManager(POOL_MANAGER), expirationInterval, CONTROLLER_MULTISIG);

        console2.log("TWAMM Hook:", hookAddress);

        require(address(twammHook) == hookAddress, "DeployScript: hook address mismatch");
    }
}
