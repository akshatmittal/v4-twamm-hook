- **Order Walking**:

  - [x] Implement `maxSwapAmount` which denotes the max delta that is swapped into the underlying pool. Extends the current tick ending logic, but more accurate due to no precision loss and explicit.
  - [x] Account for self-cancelling trades in `maxSwapAmount`.

- **Order Logic**:

  - [x] Switch to support unlocked pool manager, well, for swaps.
  - [ ] Think about unlocked pool manager more, don't think it's an issue since we use `delta` properly, but doesn't hurt thinking about it more.
  - [x] Change `submitOrder` to take `duration` instead of `endTime`.
  - [x] Update order logic has a bug with calculating owed tokens when there's multiple updates to future earnings factor.
  - [x] Remove the ability to modify orders and only allow cancelling them. Cancelling then creating a new order is equal to modifying the order, but more explicit. (removes race condition)
  - [x] Allow processing execution in batches while blocking other actions if this is necessary. (This prevents a condition where unbounded gas would brick the contract)
  - [x] Add check to disallow native token in pool.

- **Helpers**:

  - [x] Add combined function for `updateOrder` and `claimTokens`, there's no reason for them to be separate here.

- **Testing**:

  - [ ] Add more E2E flow/complex scenarios.
  - [ ] Passing through/burning all liquidity in the pool.

- **Maybe**:

  - [ ] Write an expression version of the algo?

# Open Questions

So now that we have the `maxSwapAmount` which represents a delta, the algo is calculating both the max swap and the order ending tick. Seems a bit redundant now since they are limiting the same thing in the swap. Wonder if it's worth removing the tick limit and just use the swap limit? Although, doesn't hurt keeping the tick limit since it's a bit more explicit.
