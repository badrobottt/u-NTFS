import Foundation
import AppKit
import DiskArbitration

/// Events emitted by `DiskMonitoringService` when disks appear, disappear, or change mount state.
nonisolated enum DiskMonitorEvent: Equatable, Sendable {
    case diskAppeared(bsdName: String)
    case diskDisappeared(bsdName: String)
    case diskDescriptionChanged(bsdName: String)
    case workspaceMountChanged
    case periodicRefresh
}

/// Real-time disk event monitor backed by Apple's `DiskArbitration` (`DASession`) and `NSWorkspace` notifications.
final class DiskMonitoringService {
    private var session: DASession?
    private let queue = DispatchQueue(label: "com.mountfs.ntfs.diskmonitor", qos: .utility)
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var debounceWorkItem: DispatchWorkItem?
    private var eventHandler: ((DiskMonitorEvent) -> Void)?

    init() {}

    deinit {
        stopMonitoring()
    }

    func startMonitoring(onEvent: @escaping (DiskMonitorEvent) -> Void) {
        stopMonitoring()
        self.eventHandler = onEvent

        // 1. Register DiskArbitration session callbacks for real-time hardware attach/detach/mount changes
        if let daSession = DASessionCreate(kCFAllocatorDefault) {
            self.session = daSession
            let context = Unmanaged.passUnretained(self).toOpaque()

            let appearedCallback: DADiskAppearedCallback = { disk, ctx in
                guard let ctx else { return }
                let service = Unmanaged<DiskMonitoringService>.fromOpaque(ctx).takeUnretainedValue()
                if let bsdPtr = DADiskGetBSDName(disk) {
                    let bsdName = String(cString: bsdPtr)
                    service.notifyDebounced(.diskAppeared(bsdName: bsdName))
                }
            }

            let disappearedCallback: DADiskDisappearedCallback = { disk, ctx in
                guard let ctx else { return }
                let service = Unmanaged<DiskMonitoringService>.fromOpaque(ctx).takeUnretainedValue()
                if let bsdPtr = DADiskGetBSDName(disk) {
                    let bsdName = String(cString: bsdPtr)
                    service.notifyDebounced(.diskDisappeared(bsdName: bsdName))
                }
            }

            let descriptionChangedCallback: DADiskDescriptionChangedCallback = { disk, _, ctx in
                guard let ctx else { return }
                let service = Unmanaged<DiskMonitoringService>.fromOpaque(ctx).takeUnretainedValue()
                if let bsdPtr = DADiskGetBSDName(disk) {
                    let bsdName = String(cString: bsdPtr)
                    service.notifyDebounced(.diskDescriptionChanged(bsdName: bsdName))
                }
            }

            DARegisterDiskAppearedCallback(daSession, nil, appearedCallback, context)
            DARegisterDiskDisappearedCallback(daSession, nil, disappearedCallback, context)
            DARegisterDiskDescriptionChangedCallback(daSession, nil, nil, descriptionChangedCallback, context)
            DASessionSetDispatchQueue(daSession, queue)
        }

        // 2. Observe NSWorkspace volume mount & unmount notifications
        let center = NSWorkspace.shared.notificationCenter
        let mountObs = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.notifyDebounced(.workspaceMountChanged)
        }
        let unmountObs = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.notifyDebounced(.workspaceMountChanged)
        }
        workspaceObservers = [mountObs, unmountObs]

        // 3. Fallback periodic check (every 6 seconds, matching mouNTFS)
        let timer = Timer(timeInterval: 6.0, repeats: true) { [weak self] _ in
            self?.eventHandler?(.periodicRefresh)
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopMonitoring() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        pollTimer?.invalidate()
        pollTimer = nil

        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        if let daSession = session {
            DASessionSetDispatchQueue(daSession, nil)
            session = nil
        }
    }

    nonisolated private func notifyDebounced(_ event: DiskMonitorEvent) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.debounceWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.eventHandler?(event)
            }
            self.debounceWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
        }
    }
}
