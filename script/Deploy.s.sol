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
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b; // Base

    address constant FWB_MULTISIG = 0xf34292eB10BE9cB62be70bA2058e0d683839DaBC;
    uint256 constant expirationInterval = 1 hours;

    function setUp() public {}

    function run() public {
        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(POOL_MANAGER, expirationInterval, FWB_MULTISIG);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(TWAMM).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.broadcast();
        TWAMM twammHook = new TWAMM{salt: salt}(IPoolManager(POOL_MANAGER), expirationInterval, FWB_MULTISIG);

        console2.log("TWAMM Hook:", hookAddress);

        // PoolKey memory key = PoolKey(
        //     Currency.wrap(0x4200000000000000000000000000000000000006),
        //     Currency.wrap(0xaa5aD1F869b910E5F794b9366E05E5F2cAb4bFAD),
        //     3000,
        //     60,
        //     TWAMM(0x96e3B4e76b409F10E2F89501F6ca5ABFcd92Ea80)
        // );

        require(address(twammHook) == hookAddress, "DeployScript: hook address mismatch");
    }
}
