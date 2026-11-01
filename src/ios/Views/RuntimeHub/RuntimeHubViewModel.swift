//
//  RuntimeHubViewModel.swift
//  MinisApp
//
//  [T-runtime-hub] View model for the Runtime Hub page. Boots the Linux
//  sandbox on demand (same recipe as the chat kernel boot), probes installed
//  runtimes, and drives the install pipeline with live logs. One install at
//  a time across the whole hub.
//

import Foundation
import SwiftUI

@MainActor
final class RuntimeHubViewModel: ObservableObject {

    // MARK: Published state

    @Published private(set) var states: [RuntimeID: RuntimeState] = [:]
    @Published private(set) var sandboxBooted = false
    @Published private(set) var bootMessage: String?
    @Published private(set) var installingID: RuntimeID?
    @Published private(set) var installProgress: String = ""
    @Published var lastError: String?

    /// Live log lines for the package currently being installed.
    @Published private(set) var activeLog: [String] = []

    private let installer = RuntimeInstaller.shared
    private let logger = AppLogger(category: "RuntimeHub")

    // MARK: Init

    init() {
        for pkg in RuntimeCatalog.all {
            states[pkg.id] = RuntimeStateStore.state(for: pkg.id)
        }
    }

    // MARK: Boot

    /// Boot the iSH sandbox using the same steps as the chat kernel boot path.
    func ensureSandboxBooted() {
        guard !sandboxBooted else { return }
        if ISHKernel.shared.isBooted {
            sandboxBooted = true
            bootMessage = nil
            return
        }
        bootMessage = "正在启动 Linux 沙盒…"
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try RootfsManager.shared.installIfNeeded()
                let rootPath = RootfsManager.shared.rootfsPath.path
                let err = ISHKernel.shared.boot(withRootPath: rootPath)
                if err < 0 {
                    await self.setBootFailed("内核启动失败（err=\(err)）")
                    return
                }
                MinisFsRouter.shared.installHook()
                RootfsManager.shared.applyDefaultMountOverlay()
                await MainActor.run {
                    self.sandboxBooted = true
                    self.bootMessage = nil
                    self.logger.info("[RuntimeHub] sandbox booted")
                }
            } catch {
                await self.setBootFailed(error.localizedDescription)
            }
        }
    }

    private func setBootFailed(_ message: String) {
        bootMessage = "沙盒启动失败：\(message)"
        logger.error("[RuntimeHub] boot failed: \(message)")
    }

    // MARK: Refresh

    func refresh() {
        guard sandboxBooted, installingID == nil else { return }
        Task.detached { [weak self] in
            guard let self else { return }
            for pkg in RuntimeCatalog.all {
                var state = RuntimeStateStore.state(for: pkg.id)
                guard state.status == .installed else { continue }
                let version = self.installer.probe(package: pkg)
                await MainActor.run {
                    if let version {
                        state.version = version
                        state.lastProbeError = nil
                    } else {
                        state.status = .notInstalled
                        state.lastProbeError = "probe failed on refresh"
                        state.version = nil
                    }
                    RuntimeStateStore.setState(state, for: pkg.id)
                    self.states[pkg.id] = state
                }
            }
        }
    }

    // MARK: Install

    func install(_ package: RuntimePackage, mode: RuntimeInstallMode) {
        guard installingID == nil else { return }

        // Dependency gate.
        for dep in package.dependsOn where states[dep]?.status != .installed {
            lastError = RuntimeInstallError.dependencyMissing(dep).errorDescription
            return
        }

        let hostedURL = RuntimeStateStore.hostedURL(for: package.id)
        let hostedSHA = RuntimeStateStore.hostedSHA256(for: package.id)
        if mode == .hosted {
            let trimmed = hostedURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") else {
                lastError = RuntimeInstallError.hostedPackageNotConfigured.errorDescription
                return
            }
        }

        installingID = package.id
        activeLog = []
        installProgress = "准备安装 \(package.name)…"
        lastError = nil
        setState(.installing, for: package.id)

        Task.detached { [weak self] in
            guard let self else { return }
            let logger = self.logger
            do {
                try self.installer.install(
                    package: package,
                    mode: mode,
                    hostedURL: hostedURL,
                    hostedSHA: hostedSHA
                ) { [weak self] line in
                    logger.info("[RuntimeHub][\(package.id.rawValue)] \(line)")
                    Task { @MainActor in
                        self?.activeLog.append(line)
                    }
                }

                let version = self.installer.probe(package: package)
                await self.finishInstall(package: package, version: version)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                logger.error("[RuntimeHub] install \(package.id.rawValue) failed: \(message)")
                await self.failInstall(package: package, message: message)
            }
        }
    }

    private func finishInstall(package: RuntimePackage, version: String?) {
        var state = RuntimeState()
        state.status = .installed
        state.version = version
        state.installedAt = Date()
        RuntimeStateStore.setState(state, for: package.id)
        states[package.id] = state
        installingID = nil
        installProgress = "\(package.name) 安装完成"
    }

    private func failInstall(package: RuntimePackage, message: String) {
        var state = RuntimeStateStore.state(for: package.id)
        state.status = .notInstalled
        state.lastProbeError = message
        RuntimeStateStore.setState(state, for: package.id)
        states[package.id] = state
        installingID = nil
        lastError = message
        installProgress = ""
    }

    // MARK: Uninstall

    func uninstall(_ package: RuntimePackage) {
        guard installingID == nil else { return }
        installingID = package.id
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try self.installer.uninstall(package: package) { _ in }
            } catch {
                self.logger.error("[RuntimeHub] uninstall \(package.id.rawValue): \(error.localizedDescription)")
            }
            var state = RuntimeState()
            RuntimeStateStore.setState(state, for: package.id)
            await MainActor.run {
                self.states[package.id] = state
                self.installingID = nil
            }
        }
    }

    // MARK: Hosted config

    func saveHostedConfig(package: RuntimePackage, url: String, sha: String) {
        RuntimeStateStore.setHostedURL(url, for: package.id)
        RuntimeStateStore.setHostedSHA256(sha, for: package.id)
    }

    // MARK: Helpers

    private func setState(_ status: RuntimeStatus, for id: RuntimeID) {
        var state = RuntimeStateStore.state(for: id)
        state.status = status
        if status == .installing {
            state.lastProbeError = nil
        }
        RuntimeStateStore.setState(state, for: id)
        states[id] = state
    }

    /// True when the user has provided a usable archive URL for the package.
    func hasHostedConfig(_ id: RuntimeID) -> Bool {
        let url = RuntimeStateStore.hostedURL(for: id)
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://")
    }
}
