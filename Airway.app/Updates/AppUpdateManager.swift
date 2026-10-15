import AppKit
import Combine
import Sparkle

enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String)
    case downloading(version: String, progress: Double?)
    case readyToInstall(version: String)
    case installing
    case error(message: String)

    var canPerformAction: Bool {
        switch self {
        case .idle, .upToDate, .readyToInstall, .error:
            return true
        case .checking, .updateAvailable, .downloading, .installing:
            return false
        }
    }
}

@MainActor
final class AppUpdateManager: NSObject, ObservableObject {
    @Published private(set) var state: AppUpdateState = .idle

    private var updater: SPUUpdater!
    private var userDriver: HeadlessUpdateUserDriver!
    private var updateVersion: String?
    private var expectedDownloadLength: UInt64 = 0
    private var downloadedLength: UInt64 = 0
    private var readyInstallReply: ((SPUUserUpdateChoice) -> Void)?

    override init() {
        super.init()

        // The open edition has no update feed. People who build it from
        // source update by pulling the latest code and rebuilding.
        guard AirwayEdition.isLicensed else { return }

        userDriver = HeadlessUpdateUserDriver(owner: self)
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: self
        )

        do {
            try updater.start()
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    func checkForUpdates() {
        guard state.canPerformAction, updater?.canCheckForUpdates == true else { return }
        state = .checking
        updater.checkForUpdates()
    }

    func installUpdateNow() {
        guard case .readyToInstall = state, let reply = readyInstallReply else { return }
        readyInstallReply = nil
        state = .installing
        reply(.install)
    }

    fileprivate func didBeginUserCheck() {
        state = .checking
    }

    fileprivate func didFindUpdate(version: String) {
        updateVersion = version
        state = .updateAvailable(version: version)
    }

    fileprivate func didBeginDownload() {
        expectedDownloadLength = 0
        downloadedLength = 0
        state = .downloading(version: updateVersion ?? "", progress: nil)
    }

    fileprivate func didReceiveExpectedDownloadLength(_ length: UInt64) {
        expectedDownloadLength = length
        publishDownloadProgress()
    }

    fileprivate func didReceiveDownloadData(length: UInt64) {
        downloadedLength += length
        publishDownloadProgress()
    }

    fileprivate func didReceiveExtractionProgress(_ progress: Double) {
        state = .downloading(
            version: updateVersion ?? "",
            progress: min(max(progress, 0), 1)
        )
    }

    fileprivate func didBecomeReadyToInstall(
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        readyInstallReply = reply
        state = .readyToInstall(version: updateVersion ?? "")
    }

    fileprivate func didNotFindUpdate() {
        state = .upToDate
    }

    fileprivate func didFail(with error: Error) {
        readyInstallReply = nil
        state = .error(message: error.localizedDescription)
    }

    fileprivate func didBeginInstalling() {
        state = .installing
    }

    private func publishDownloadProgress() {
        let progress: Double? = expectedDownloadLength > 0
            ? min(Double(downloadedLength) / Double(expectedDownloadLength), 1)
            : nil
        state = .downloading(version: updateVersion ?? "", progress: progress)
    }
}

extension AppUpdateManager: SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        shouldDownloadReleaseNotesForUpdate item: SUAppcastItem
    ) -> Bool {
        false
    }
}

@MainActor
private final class HeadlessUpdateUserDriver: NSObject, SPUUserDriver {
    private weak var owner: AppUpdateManager?

    init(owner: AppUpdateManager) {
        self.owner = owner
    }

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        owner?.didBeginUserCheck()
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        if appcastItem.isInformationOnlyUpdate {
            if state.userInitiated, let infoURL = appcastItem.infoURL {
                NSWorkspace.shared.open(infoURL)
            }
            owner?.didNotFindUpdate()
            reply(.dismiss)
            return
        }

        owner?.didFindUpdate(version: appcastItem.displayVersionString)
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(
        _ error: Error,
        acknowledgement: @escaping () -> Void
    ) {
        owner?.didNotFindUpdate()
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        owner?.didFail(with: error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        owner?.didBeginDownload()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        owner?.didReceiveExpectedDownloadLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        owner?.didReceiveDownloadData(length: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        owner?.didReceiveExtractionProgress(0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        owner?.didReceiveExtractionProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        owner?.didBecomeReadyToInstall(reply: reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        owner?.didBeginInstalling()
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {}

    func showUpdateInFocus() {}
}
