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
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

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
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        vm.warp(10_000);

        bytes memory constructorArgs = abi.encode(manager, uint256(10_000), address(123));
        deployCodeTo("TWAMM.sol:TWAMM", constructorArgs, flags);
        twammHook = TWAMM(flags);

        // key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, twammHook);
        key = PoolKey(currency0, currency1, 3000, 60, twammHook);
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_4);

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
     * This file isn't a real test.
     */
    function test_TWAMM_Uneven_Playground() public {
        uint256 orderDuration = 20_000;

        // BalanceDelta delta = swap(key, true, -int256(80 ether), ZERO_BYTES);
        // console2.log("delta0", delta.amount0());
        // console2.log("delta1", delta.amount1());

        vm.warp(10_000);
        ITWAMM.OrderKey memory oKey1 = _submitOrderAs(address(0xB1), true, 80 ether, orderDuration);
        ITWAMM.OrderKey memory oKey2 = _submitOrderAs(address(0xB2), false, 10 ether, orderDuration);

        console2.log("twammBalance0 %18e", token0.balanceOf(address(twammHook)));
        console2.log("twammBalance1 %18e", token1.balanceOf(address(twammHook)));

        vm.warp(10_000 * 10);
        console2.log("------");
        twammHook.executeTWAMMOrders(key);
        console2.log("------");

        console2.log("twammBalance0 %18e", token0.balanceOf(address(twammHook)));
        console2.log("twammBalance1 %18e", token1.balanceOf(address(twammHook)));

        _updateOrderAndClaim(oKey1);
        _updateOrderAndClaim(oKey2);

        (, uint256 ef0) = twammHook.getOrderPool(key, true);
        (, uint256 ef1) = twammHook.getOrderPool(key, false);

        console2.log("ef0", ef0);
        console2.log("ef1", ef1);

        assertApproxEqRel(key.currency1.balanceOf(address(0xB1)), 20 ether, 0.02e18);
        assertApproxEqRel(key.currency0.balanceOf(address(0xB2)), 40 ether, 0.02e18);

        console2.log("twammBalance0 %18e", token0.balanceOf(address(twammHook)));
        console2.log("twammBalance1 %18e", token1.balanceOf(address(twammHook)));
    }

    function test_TWAMM_Killed() external {
        vm.warp(10_000);
        ITWAMM.OrderKey memory oKey1 = _submitOrderAs(address(0xB1), true, 1 ether, 20_000);

        vm.warp(20_000);
        _updateOrderAndClaim(oKey1);

        vm.startPrank(address(123));
        twammHook.killHook();
        vm.stopPrank();

        vm.warp(100_000);
        vm.startPrank(address(0xB1));
        twammHook.syncAndClaimTokens(ITWAMM.SyncParams({key: key, orderKey: oKey1}));
        vm.stopPrank();

        console2.log("Balance0 %18e", token0.balanceOf(address(0xB1)));
        console2.log("Balance1 %18e", token1.balanceOf(address(0xB1)));
    }

    function _updateOrderAndClaim(ITWAMM.OrderKey memory oKey) internal {
        vm.startPrank(oKey.owner);
        twammHook.syncAndClaimTokens(ITWAMM.SyncParams({key: key, orderKey: oKey}));

        vm.stopPrank();
    }

    function _submitOrderAs(address owner, bool zeroForOne, uint256 amount, uint256 duration)
        internal
        returns (ITWAMM.OrderKey memory oKey)
    {
        if (zeroForOne) {
            token0.transfer(address(owner), amount);
        } else {
            token1.transfer(address(owner), amount);
        }

        vm.startPrank(owner);
        if (zeroForOne) {
            token0.approve(address(twammHook), amount);
        } else {
            token1.approve(address(twammHook), amount);
        }

        (, oKey) = twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: duration, amountIn: amount})
        );
        vm.stopPrank();
    }

    function _submitOrderSingleDirection(bool zeroForOne, uint256 amount, uint256 duration)
        internal
        returns (ITWAMM.OrderKey memory oKey)
    {
        oKey = ITWAMM.OrderKey(address(this), uint160(block.timestamp + duration), zeroForOne);

        token0.approve(address(twammHook), amount);
        token1.approve(address(twammHook), amount);

        twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: duration, amountIn: amount})
        );
    }
}
