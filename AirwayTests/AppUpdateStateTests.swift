import Testing
@testable import Airway

struct AppUpdateStateTests {
    @Test func onlyIdleTerminalAndReadyStatesAllowButtonActions() {
        #expect(AppUpdateState.idle.canPerformAction)
        #expect(AppUpdateState.upToDate.canPerformAction)
        #expect(AppUpdateState.readyToInstall(version: "0.6").canPerformAction)
        #expect(AppUpdateState.error(message: "Offline").canPerformAction)

        #expect(!AppUpdateState.checking.canPerformAction)
        #expect(!AppUpdateState.updateAvailable(version: "0.6").canPerformAction)
        #expect(!AppUpdateState.downloading(version: "0.6", progress: 0.5).canPerformAction)
        #expect(!AppUpdateState.installing.canPerformAction)
    }
}
