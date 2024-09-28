- **Order Walking**:

  - [ ] Account for self-cancelling trades in `maxSwapAmount`.

- **Order Logic**:

  - [ ] Think about unlocked pool manager more, don't think it's an issue since we use `delta` properly, but doesn't hurt thinking about it more.
  - [x] Change `submitOrder` to take `duration` instead of `endTime`.
  - [x] Update order logic has a bug with calculating owed tokens when there's multiple updates to future earnings factor.
  - [ ] Remove the ability to modify orders and only allow cancelling them. Cancelling then creating a new order is equal to modifying the order.

- **Helpers**:

  - [ ] Add combined function for `updateOrder` and `claimTokens`, there's no reason for them to be separate here.

- **Testing**:

  - [ ] Add more E2E flow tests.

- **Maybe**:

  - [ ] Write an expression version of the algo?
