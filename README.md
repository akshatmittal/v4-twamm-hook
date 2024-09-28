# TWAMM Hook for Uniswap V4

This hook implements the TWAMM (Time-Weighted Average Market Maker) strategy for Uniswap V4. The strategy is explained in detail in the [TWAMM explainer](https://www.paradigm.xyz/2021/07/twamm) by Paradigm.

This implementation specifically implements the TWAMM Order Strategy using a Hook on the Uniswap V4 Pool. Given that this is implemented entirely onchain, there are additional considerations associated with it.

## Considerations

- **MEV**: Since the hook is entirely onchain, there are several MEV related consideration explained in the next section.
- **Execution Price**: The TWAMM orders are executed in the pool they are attached to, which means the execution is limited by the liquidity available in the pool.
  - This can lead to high price impact for large orders or when liquidity is limited, especially when the pool is not the primary liquidity source for the token.
  - While the price impact of individual trades can have a negative impact on the overall execution price, the hook does allow executing TWAMM orders out-of-the-loop, this enables MEV to take action _as soon as_ an opportunity of any size is present. This makes the strategy more competitive in the presence of MEV. (See the _MEV Considerations_ section below)
- **Execution Interval & Duration**: The TWAMM orders are executed at fixed intervals for the specified duration. While placing the order, the user should consider the interval and duration to ensure that the order is executed in the right manner.
  - If the duration is too small and the order is split into only a handful of trades, each individual order will still be large and can have high price impact.
  - If the duration is too large, you are effectively taking a position for a longer duration. This may not be desirable based on what you're trying to achieve.
- **Tracking & Fees**: This TWAMM implementation tracks orders using a rate instead of accounting each individual order separately. This significantly improves performance. However, this also means that trades in the opposite direction of each other simply cancel out instead of being traded into the pool, effectively bypassing the pool fee for those orders. Any amount that's not cancelled out is traded into the pool and incurs the pool fee.

## MEV Considerations

- **Price Consideration**: See the _Execution Price_ section above.
- **Front Running Protection**: The TWAMM orders are executed _before_ another swap or liquidity change. Effectively, this means that the TWAMM orders can _not_ be front-run. (However, other price related considerations still apply)
- **MEV Chain**: Since all TWAMM orders are simply just long term orders that anyone can execute, it does open up some interesting MEV opportunities and can leak some value.
  - If a TWAMM order is in a state where it would move the price in the pool by enough value that it creates an arbitrage with another pool, MEV is incentivized to execute the TWAMM order and capitalize on the arbitrage opportunity. This is a _good_ thing since it means that the TWAMM order is being executed at the current market price, although while leaking _some_ value.
- **Information Leakage**: This is not specific to this implementation but is a general consideration for all TWAMM mechanisms. Since the TWAMM orders are public, they leak _information_ that a trade of this size is coming to the market. You should always keep this in mind, although it is possible to cancel the TWAMM order if the market conditions change.
- **Informed Order Flow**: Related to the previous point, an informed actor can create a trade in the opposite direction of existing trades to effectively trade without a fee for any overlapping amount. That said, they are still subject to the price risk of the asset involved. The hook prevents this somewhat by ensuring that the TWAMM orders are executed before new orders are accepted.
