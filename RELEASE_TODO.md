# Release TODO

Before the next AirDesk release, complete and verify every item below. Remove each item after it is finished. Delete this file when no items remain.

- [ ] Add a short note to the Remote Access paywall that purchases are handled securely by Apple and the user may be asked to sign in to their Apple Account.
- [ ] Add an optional `Redeem Offer Code` action for Remote Access plans using Apple's StoreKit offer-code redemption UI. Do not add a custom HelloX unlock-code flow for App Store builds.
- [ ] Verify an Apple offer-code redemption path: redeem a Pro offer code, open AirDesk, confirm `RemoteAccessSubscriptionStore` refreshes the Pro entitlement, and confirm `Restore Purchases` fixes the state if it does not update immediately.
- [ ] Update the iOS QA plan with an offer-code redemption case and a restore-after-redemption case.
- [ ] Update release notes/changelog for the paywall and offer-code UX changes.
