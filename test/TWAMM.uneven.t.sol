// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

import {TWAMM, ITWAMM} from "@src/TWAMM.sol";

contract TWAMMUnevenTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    TWAMM twammHook;
    PoolId poolId;

    MockERC20 token0;
    MockERC20 token1;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        vm.label(address(token0), "Token0");
        vm.label(address(token1), "Token1");

        address flags = address(
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG)
                ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        vm.warp(10_000);

        bytes memory constructorArgs = abi.encode(manager, uint256(10_000));
        deployCodeTo("TWAMM.sol:TWAMM", constructorArgs, flags);
        twammHook = TWAMM(flags);

        // key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, twammHook);
        key = PoolKey(currency0, currency1, 3000, 60, twammHook);
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_4, ZERO_BYTES);

        // This test assumes effectively unlimited liquidity
        posm.mint(
            key,
            key.tickSpacing * -1,
            key.tickSpacing * 1,
            1000 ether,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
        posm.mint(
            key,
            key.tickSpacing * -2,
            key.tickSpacing * 2,
            1000 ether,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
        posm.mint(
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            1000 ether,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }

    /**
     * This isn't a real test.
     */
    function test_TWAMM_Uneven_Playground() public {
        uint256 orderDuration = 20_000;

        vm.warp(10_000);
        ITWAMM.OrderKey memory oKey1 = _submitOrderSingleDirection(true, 80 ether, orderDuration);
        ITWAMM.OrderKey memory oKey2 = _submitOrderSingleDirection(false, 25 ether, orderDuration);

        console2.log("twammBalance0", token0.balanceOf(address(twammHook)));
        console2.log("twammBalance1", token1.balanceOf(address(twammHook)));

        vm.warp(30_000);
        twammHook.executeTWAMMOrders(key);

        console2.log("twammBalance0", token0.balanceOf(address(twammHook)));
        console2.log("twammBalance1", token1.balanceOf(address(twammHook)));

        twammHook.sync(key, oKey1, false);
        twammHook.sync(key, oKey2, false);
    }

    function _submitOrderAs(address owner, bool zeroForOne, uint256 amount, uint160 duration)
        internal
        returns (ITWAMM.OrderKey memory oKey)
    {
        token0.transfer(address(owner), amount);
        token1.transfer(address(owner), amount);

        vm.startPrank(owner);
        token0.approve(address(twammHook), amount);
        token1.approve(address(twammHook), amount);

        oKey = ITWAMM.OrderKey(owner, uint160(block.timestamp) + duration, zeroForOne);

        twammHook.submitOrder(key, zeroForOne, duration, amount);
        vm.stopPrank();
    }

    function _submitOrderSingleDirection(bool zeroForOne, uint256 amount, uint256 duration)
        internal
        returns (ITWAMM.OrderKey memory oKey)
    {
        oKey = ITWAMM.OrderKey(address(this), uint160(block.timestamp + duration), zeroForOne);

        token0.approve(address(twammHook), amount);
        token1.approve(address(twammHook), amount);

        twammHook.submitOrder(key, zeroForOne, duration, amount);
    }
}
