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

import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

import {TWAMM, ITWAMM} from "@src/TWAMM.sol";

uint256 constant TWAMM_INTERVAL = 30 * 60; // 30 mins, a bit more realistic.

contract TWAMMComplexTest is Test, Fixtures {
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

        vm.warp(TWAMM_INTERVAL);

        bytes memory constructorArgs = abi.encode(manager, TWAMM_INTERVAL, address(123)); // Uses 30 mins
        deployCodeTo("TWAMM.sol:TWAMM", constructorArgs, flags);
        twammHook = TWAMM(flags);

        key = PoolKey(currency0, currency1, 3000, 60, twammHook);
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // This test assumes effectively unlimited liquidity
        posm.mint(
            key,
            key.tickSpacing * -10,
            key.tickSpacing * 10,
            10000 ether,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
        posm.mint(
            key,
            key.tickSpacing * -20,
            key.tickSpacing * 20,
            10000 ether,
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
            10000 ether,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }

    function test_TWAMM_Complex_Scenario1() public {
        // Time that's not a multiple of the interval
        vm.warp(TWAMM_INTERVAL * 2 + 12); // Delta = 0, 0
        ITWAMM.OrderKey memory oKey1 = _submitOrderAs(address(0xB1), true, 1 ether, TWAMM_INTERVAL * 10);

        vm.warp(TWAMM_INTERVAL * 3 + 13); // Delta = 1, 1
        ITWAMM.OrderKey memory oKey2 = _submitOrderAs(address(0xB2), true, 2 ether, TWAMM_INTERVAL * 10);

        vm.warp(TWAMM_INTERVAL * 5 + 14); // Delta = 2, 3
        ITWAMM.OrderKey memory oKey3 = _submitOrderAs(address(0xB3), false, 3 ether, TWAMM_INTERVAL * 10);

        vm.warp(TWAMM_INTERVAL * 7 + 15); // Delta = 2, 5
        ITWAMM.OrderKey memory oKey4 = _submitOrderAs(address(0xB4), false, 4 ether, TWAMM_INTERVAL * 10);

        vm.warp(TWAMM_INTERVAL * 8 + 16); // Delta = 1, 6
        ITWAMM.OrderKey memory oKey5 = _submitOrderAs(address(0xB5), false, 5 ether, TWAMM_INTERVAL * 10);

        vm.warp(TWAMM_INTERVAL * 9 + 17); // Delta = 1, 7
        ITWAMM.OrderKey memory oKey6 = _submitOrderAs(address(0xB6), true, 10 ether, TWAMM_INTERVAL * 10);

        vm.warp(TWAMM_INTERVAL * 10 + 18); // Delta = 1, 8
        ITWAMM.OrderKey memory oKey7 = _submitOrderAs(address(0xB7), false, 20 ether, TWAMM_INTERVAL * 10);

        vm.warp(TWAMM_INTERVAL * 12 + 19); // Delta = 2, 10
        ITWAMM.OrderKey memory oKey8 = _submitOrderAs(address(0xB8), false, 30 ether, TWAMM_INTERVAL * 10);

        // Future future.
        vm.warp(TWAMM_INTERVAL * 50);

        // Update all orders
        _updateOrderAndClaim(oKey1);
        _updateOrderAndClaim(oKey2);
        _updateOrderAndClaim(oKey3);
        _updateOrderAndClaim(oKey4);
        _updateOrderAndClaim(oKey5);
        _updateOrderAndClaim(oKey6);
        _updateOrderAndClaim(oKey7);
        _updateOrderAndClaim(oKey8);

        // Make sure everyone got what they expected
        assertApproxEqRel(key.currency1.balanceOf(address(0xB1)), 1 ether, 0.02e18);
        assertApproxEqRel(key.currency1.balanceOf(address(0xB2)), 2 ether, 0.02e18);
        assertApproxEqRel(key.currency0.balanceOf(address(0xB3)), 3 ether, 0.02e18);
        assertApproxEqRel(key.currency0.balanceOf(address(0xB4)), 4 ether, 0.02e18);
        assertApproxEqRel(key.currency0.balanceOf(address(0xB5)), 5 ether, 0.02e18);
        assertApproxEqRel(key.currency1.balanceOf(address(0xB6)), 10 ether, 0.02e18);
        assertApproxEqRel(key.currency0.balanceOf(address(0xB7)), 20 ether, 0.02e18);
        assertApproxEqRel(key.currency0.balanceOf(address(0xB8)), 30 ether, 0.02e18);
    }

    function test_TWAMM_Complex_Scenario2() public {
        // Time that's not a multiple of the interval
        vm.warp(TWAMM_INTERVAL * 2 + 12); // Delta = 0, 0
        ITWAMM.OrderKey memory oKey1 = _submitOrderAs(address(0xB1), true, 1 ether, TWAMM_INTERVAL * 10);

        vm.warp(TWAMM_INTERVAL * 3 + 13); // Delta = 1, 1
        ITWAMM.OrderKey memory oKey2 = _submitOrderAs(address(0xB2), true, 1 ether, TWAMM_INTERVAL * 10);

        vm.warp(TWAMM_INTERVAL * 5 + 14); // Delta = 2, 3
        ITWAMM.OrderKey memory oKey3 = _submitOrderAs(address(0xB3), false, 1 ether, TWAMM_INTERVAL * 10);

        vm.warp(TWAMM_INTERVAL * 17 + 15); // Delta = 12, 15
        ITWAMM.OrderKey memory oKey4 = _submitOrderAs(address(0xB4), false, 1 ether, TWAMM_INTERVAL * 10);

        vm.warp(TWAMM_INTERVAL * 18 + 16); // Delta = 1, 16
        ITWAMM.OrderKey memory oKey5 = _submitOrderAs(address(0xB5), false, 1 ether, TWAMM_INTERVAL * 10);

        vm.warp(TWAMM_INTERVAL * 19 + 17); // Delta = 1, 17
        ITWAMM.OrderKey memory oKey6 = _submitOrderAs(address(0xB6), true, 10 ether, TWAMM_INTERVAL * 10);

        vm.warp(TWAMM_INTERVAL * 20 + 18); // Delta = 1, 18
        ITWAMM.OrderKey memory oKey7 = _submitOrderAs(address(0xB7), false, 10 ether, TWAMM_INTERVAL * 10);

        vm.warp(TWAMM_INTERVAL * 22 + 19); // Delta = 2, 20
        ITWAMM.OrderKey memory oKey8 = _submitOrderAs(address(0xB8), false, 10 ether, TWAMM_INTERVAL * 10);

        // Future future.
        vm.warp(TWAMM_INTERVAL * 50);

        // Update all orders
        _updateOrderAndClaim(oKey1);
        _updateOrderAndClaim(oKey2);
        _updateOrderAndClaim(oKey3);
        _updateOrderAndClaim(oKey4);
        _updateOrderAndClaim(oKey5);
        _updateOrderAndClaim(oKey6);
        _updateOrderAndClaim(oKey7);
        _updateOrderAndClaim(oKey8);

        // Make sure everyone got what they expected
        assertApproxEqRel(key.currency1.balanceOf(address(0xB1)), 1 ether, 0.01e18);
        assertApproxEqRel(key.currency1.balanceOf(address(0xB2)), 1 ether, 0.01e18);
        assertApproxEqRel(key.currency0.balanceOf(address(0xB3)), 1 ether, 0.01e18);
        assertApproxEqRel(key.currency0.balanceOf(address(0xB4)), 1 ether, 0.01e18);
        assertApproxEqRel(key.currency0.balanceOf(address(0xB5)), 1 ether, 0.01e18);
        assertApproxEqRel(key.currency1.balanceOf(address(0xB6)), 10 ether, 0.01e18);
        assertApproxEqRel(key.currency0.balanceOf(address(0xB7)), 10 ether, 0.01e18);
        assertApproxEqRel(key.currency0.balanceOf(address(0xB8)), 10 ether, 0.01e18);
    }

    function test_TWAMM_Complex_Scenario3() public {
        // Time that's not a multiple of the interval
        vm.warp(TWAMM_INTERVAL * 2 + 12);
        ITWAMM.OrderKey memory oKey1 = _submitOrderAs(address(0xB1), true, 1 ether, TWAMM_INTERVAL * 10);
        ITWAMM.OrderKey memory oKey2 = _submitOrderAs(address(0xB2), false, 1 ether, TWAMM_INTERVAL * 10);

        // Future future.
        vm.warp(TWAMM_INTERVAL * 50);

        // Update all orders
        _updateOrderAndClaim(oKey1);
        _updateOrderAndClaim(oKey2);

        // Make sure everyone got what they expected
        assertApproxEqRel(key.currency1.balanceOf(address(0xB1)), 1 ether, 0.01e18);
        assertApproxEqRel(key.currency0.balanceOf(address(0xB2)), 1 ether, 0.01e18);
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
        token0.approve(address(twammHook), amount);
        token1.approve(address(twammHook), amount);

        (, oKey) = twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: duration, amountIn: amount})
        );
    }
}
