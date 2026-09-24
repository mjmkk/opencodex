# Real-device recovery regression

This Xcode UI test uses the installed OpenCodex app and its real service/cache. It does not create fixtures, mock API responses, or submit messages/approvals.

1. Build and install the current Release app as `chenken.CodexWorkerApp` on the chosen simulator. Keep its real Spirit Master configuration and cached AGT-12 history.
2. Open `Recovery.xcodeproj`, choose that same simulator, and run the `Recovery` scheme (Product > Test).
3. The test selects AGT-12, reads a visible real message, terminates and relaunches the app, then requires the same task and cached message with no CancellationError. Screenshots and accessibility snapshots stay in the result bundle.

The installed app and real cache are prerequisites; absence is a setup failure, not a passing test. This test does not prove APNs delivery, offline rendering, or physical iPhone acceptance. Physical-device runs require signing the UI test runner with the local development team.
