# Release TODO

Before any AirDesk release, complete and verify every item below. Remove each item after it is finished. Keep this file even when no items remain.

- [ ] Rebuild and resubmit iOS `1.2.10` with an Apple-supported Xcode/SDK RC. App Store Connect rejected build `21` with `ITMS-90111: Unsupported SDK or Xcode version` after upload/submission. Current blocker: this Mac is on macOS `27.0 (26A5353q)`, where Xcode `26.6 RC (17F109)` is not supported, while Xcode `27.0 beta (27A5194q)` is only suitable for TestFlight beta uploads and should not be used for App Store review. Required path: build on a macOS 26-compatible Mac/CI/Xcode Cloud runner with Xcode `26.6 RC`, or wait until Apple supports App Store submissions from Xcode 27 RC.
