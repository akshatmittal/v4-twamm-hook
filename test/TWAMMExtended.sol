// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TWAMM, IPoolManager, PoolId, PoolKey} from "@src/TWAMM.sol";

contract TWAMMExtended is TWAMM {
    constructor(IPoolManager _manager, uint256 _exp, address initialOwner) TWAMM(_manager, _exp, initialOwner) {}

    function getOrderPoolEarningsFactorAtInterval(PoolId id, bool zeroForOne, uint256 timestamp)
        external
        view
        returns (uint256 earningsFactor)
    {
        if (zeroForOne) {
            return twammStates[id].orderPool0For1.earningsFactorAtInterval[timestamp];
        } else {
            return twammStates[id].orderPool1For0.earningsFactorAtInterval[timestamp];
        }
    }

    function isCrossingInitializedTick(
        PoolParamsOnExecute memory pool,
        PoolKey memory poolKey,
        uint160 nextSqrtPriceX96
    ) external view returns (bool crossingInitializedTick, int24 nextTickInit) {
        return _isCrossingInitializedTick(pool, poolKey, nextSqrtPriceX96);
    }
}
