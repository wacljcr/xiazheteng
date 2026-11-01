//
//  RuntimeInstaller.swift
//  MinisApp
//
//  [T-runtime-hub] Install pipeline for Runtime Hub packages.
//
//  Nothing ships inside the app. Two install modes:
//
//    .hosted (primary) — download the user-provided archive (GitHub repo /
//                        release asset) inside the guest, verify SHA-256 when
//                        configured, extract to /opt/<id>, probe.
//    .script (fallback) — in-guest recipe: apk add + post-install script.
//
//  Both modes end with real probes; any failure rolls the /opt snapshot back.
//  All guest execution goes through ISHShellExecutor's synchronous API on a
//  dedicated serial queue, so installs never interleave with the agent's
//  per-session execution coordinator.
//

import Foundation

struct RuntimeShellOutcome: Sendable {
    let exitCode: Int32
    let output: String
    let errorOutput: String

    var ok: Bool { exitCode == 0 }
    var firstLine: String {
        let line = output.split(separator: "\n").first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }
    var combinedTail: String {
        let text = errorOutput.isEmpty ? output : output + "\n" + errorOutput
        return text
            .split(separator: "\n")
            .suffix(12)
            .joined(separator: "\n")
    }
}

enum RuntimeInstallError: LocalizedError {
    case kernelNotBooted
    case dependencyMissing(RuntimeID)
    case hostedPackageNotConfigured
    case scriptModeNotAvailable
    case stepFailed(String, RuntimeShellOutcome)
    case probeFailed(String, RuntimeShellOutcome)
    case shaMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .kernelNotBooted:
            return "Linux 沙盒尚未启动，请先打开一次终端完成 rootfs 初始化"
        case .dependencyMissing(let id):
            return "需要先安装依赖：\(RuntimeCatalog.package(id).name)"
        case .hostedPackageNotConfigured:
            return "当前包未内置：请先在本页填写 Runtime 包下载地址（GitHub 仓库 / Release 附件）"
        case .scriptModeNotAvailable:
            return "该包没有内置安装脚本，请使用托管包方式安装"
        case .stepFailed(let step, let outcome):
            let tail = outcome.combinedTail.split(separator: "\n").last.map(String.init) ?? "无输出"
            return "步骤失败 [\(step)]（exit \(outcome.exitCode)）：\(tail)"
        case .probeFailed(let probe, let outcome):
            return "安装后探针未通过 [\(probe)]（exit \(outcome.exitCode)）"
        case .shaMismatch(let expected, let actual):
            return "SHA-256 校验失败：期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…"
        }
    }
}

// MARK: - Shell bridge

/// Serial wrapper around ISHShellExecutor's synchronous API. `@unchecked
/// Sendable` is safe: the only state is the serial queue itself, which is
/// created once and never mutated.
final class RuntimeShellBridge: @unchecked Sendable {

    static let shared = RuntimeShellBridge()

    private let queue = DispatchQueue(label: "app.openminis.runtimehub.shell", qos: .userInitiated)

    func run(_ command: String, timeout: TimeInterval) -> RuntimeShellOutcome {
        queue.sync {
            guard ISHKernel.shared.isBooted else {
                return RuntimeShellOutcome(exitCode: -1, output: "", errorOutput: "kernel not booted")
            }
            let result = ISHShellExecutor.executeCommandSync(command, timeout: timeout, lineCallback: nil)
            return RuntimeShellOutcome(
                exitCode: Int32(result.exitCode),
                output: result.output as String,
                errorOutput: result.errorOutput as String
            )
        }
    }
}

// MARK: - Installer

final class RuntimeInstaller: @unchecked Sendable {

    static let shared = RuntimeInstaller()

    private let shell = RuntimeShellBridge.shared

    private let apkTimeout: TimeInterval = 15 * 60
    private let scriptTimeout: TimeInterval = 60 * 60
    private let hostedTimeout: TimeInterval = 60 * 60
    private let probeTimeout: TimeInterval = 60

    // MARK: Probes

    /// Run the package's probes. Returns the first version-looking output line,
    /// or nil when any probe fails.
    func probe(package: RuntimePackage) -> String? {
        for probe in package.probes {
            let outcome = shell.run(probe.command, timeout: probeTimeout)
            guard outcome.ok else { return nil }
        }
        for probe in package.probes {
            let outcome = shell.run(probe.command, timeout: probeTimeout)
            let line = outcome.firstLine
            if line.contains(where: { $0.isNumber }) {
                return line
            }
        }
        return package.probes.isEmpty ? nil : "已就绪"
    }

    // MARK: Install

    func install(
        package: RuntimePackage,
        mode: RuntimeInstallMode,
        hostedURL: String,
        hostedSHA: String,
        log: @escaping @Sendable (String) -> Void
    ) throws {
        guard ISHKernel.shared.isBooted else { throw RuntimeInstallError.kernelNotBooted }

        switch mode {
        case .hosted:
            try installHosted(package: package, hostedURL: hostedURL, hostedSHA: hostedSHA, log: log)
        case .script:
            try installScript(package: package, log: log)
        }
    }

    // MARK: Hosted mode

    private func installHosted(
        package: RuntimePackage,
        hostedURL: String,
        hostedSHA: String,
        log: @escaping @Sendable (String) -> Void
    ) throws {
        let url = hostedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("https://") || url.hasPrefix("http://") else {
            throw RuntimeInstallError.hostedPackageNotConfigured
        }

        let dest = "/opt/\(package.id.rawValue)"
        let backup = "/opt/.\(package.id.rawValue).autobak"

        // Snapshot any previous payload so we can roll back on failure.
        let snapshot = shell.run(
            "if [ -d \(dest) ]; then rm -rf \(backup); mv \(dest) \(backup); echo moved; else echo absent; fi",
            timeout: probeTimeout
        )
        let hadBackup = snapshot.output.contains("moved")

        do {
            log("$ curl → \(url)")
            let work = "/tmp/runtimehub-\(package.id.rawValue)"
            let fetch = """
            set -e
            rm -rf \(work) && mkdir -p \(work)
            curl -fL --retry 2 '\(url)' -o \(work)/pkg.bin 2>&1 | tail -n 2
            sha256sum \(work)/pkg.bin
            """
            let fetchOutcome = shell.run(fetch, timeout: hostedTimeout)
            emitTail(of: fetchOutcome, into: log)
            guard fetchOutcome.ok else { throw RuntimeInstallError.stepFailed("download", fetchOutcome) }

            let wanted = hostedSHA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !wanted.isEmpty {
                let actual = fetchOutcome.output
                    .split(separator: "\n")
                    .compactMap { $0.split(separator: " ").first.map(String.init) }
                    .last ?? ""
                guard actual == wanted else {
                    throw RuntimeInstallError.shaMismatch(expected: wanted, actual: actual)
                }
                log("✓ SHA-256 校验通过")
            } else {
                log("（未配置 SHA-256，跳过校验）")
            }

            log("$ 解压到 \(dest)")
            let extract = """
            set -e
            rm -rf \(dest) && mkdir -p \(dest)
            case '\(url)' in
              *.tar.xz|*.txz) tar -xJf \(work)/pkg.bin -C \(dest) ;;
              *.tar.gz|*.tgz) tar -xzf \(work)/pkg.bin -C \(dest) ;;
              *)              tar -xf  \(work)/pkg.bin -C \(dest) ;;
            esac
            rm -rf \(work)
            # 有些包会把内容套一层顶层目录，压平它
            if [ $(ls -A \(dest) | wc -l) -eq 1 ] && [ -d \(dest)/* ] 2>/dev/null; then
              inner=$(ls -A \(dest))
              mv \(dest)/$inner/* \(dest)/ 2>/dev/null || true
              rmdir \(dest)/$inner 2>/dev/null || true
            fi
            echo extracted
            """
            let extractOutcome = shell.run(extract, timeout: hostedTimeout)
            emitTail(of: extractOutcome, into: log)
            guard extractOutcome.ok else { throw RuntimeInstallError.stepFailed("extract", extractOutcome) }

            try runProbes(package: package, log: log)
        } catch {
            if hadBackup {
                log("↩ 回滚 \(dest)")
                _ = shell.run("rm -rf \(dest); mv \(backup) \(dest)", timeout: probeTimeout)
            }
            throw error
        }

        if hadBackup {
            _ = shell.run("rm -rf \(backup)", timeout: probeTimeout)
        }
    }

    // MARK: Script mode

    private func installScript(
        package: RuntimePackage,
        log: @escaping @Sendable (String) -> Void
    ) throws {
        guard package.supportsScriptFallback else { throw RuntimeInstallError.scriptModeNotAvailable }

        let dest = "/opt/\(package.id.rawValue)"
        let backup = "/opt/.\(package.id.rawValue).autobak"
        var hadBackup = !package.postInstallScript.isEmpty
        if hadBackup {
            let snapshot = shell.run(
                "if [ -d \(dest) ]; then rm -rf \(backup); mv \(dest) \(backup); echo moved; else echo absent; fi",
                timeout: probeTimeout
            )
            hadBackup = snapshot.output.contains("moved")
        }

        do {
            if !package.apkPackages.isEmpty {
                let list = package.apkPackages.joined(separator: " ")
                log("$ apk add --no-cache \(list)")
                let outcome = shell.run("apk add --no-cache \(list) 2>&1", timeout: apkTimeout)
                emitTail(of: outcome, into: log)
                guard outcome.ok else { throw RuntimeInstallError.stepFailed("apk add", outcome) }
            }

            if !package.postInstallScript.isEmpty {
                log("$ /bin/sh（安装脚本）")
                let outcome = shell.run(package.postInstallScript, timeout: scriptTimeout)
                emitTail(of: outcome, into: log)
                guard outcome.ok else { throw RuntimeInstallError.stepFailed("install script", outcome) }
            }

            try runProbes(package: package, log: log)
        } catch {
            if hadBackup {
                log("↩ 回滚 \(dest)")
                _ = shell.run("rm -rf \(dest); mv \(backup) \(dest)", timeout: probeTimeout)
            }
            throw error
        }

        if hadBackup {
            _ = shell.run("rm -rf \(backup)", timeout: probeTimeout)
        }
    }

    // MARK: Shared

    private func runProbes(package: RuntimePackage, log: @escaping @Sendable (String) -> Void) throws {
        for probe in package.probes {
            let outcome = shell.run(probe.command, timeout: probeTimeout)
            guard outcome.ok else {
                log("✗ 探针未通过：\(probe.label)")
                throw RuntimeInstallError.probeFailed(probe.label, outcome)
            }
            log("✓ \(probe.label): \(outcome.firstLine.isEmpty ? "ok" : outcome.firstLine)")
        }
    }

    // MARK: Uninstall

    func uninstall(package: RuntimePackage, log: @escaping @Sendable (String) -> Void) throws {
        if !package.apkPackages.isEmpty {
            let list = package.apkPackages.joined(separator: " ")
            log("$ apk del \(list)")
            let outcome = shell.run("apk del \(list) 2>&1 || true", timeout: apkTimeout)
            emitTail(of: outcome, into: log)
        }
        log("$ rm -rf /opt/\(package.id.rawValue)")
        _ = shell.run("rm -rf /opt/\(package.id.rawValue) /opt/.\(package.id.rawValue).autobak", timeout: probeTimeout)
    }

    private func emitTail(of outcome: RuntimeShellOutcome, into log: @escaping @Sendable (String) -> Void) {
        for line in outcome.combinedTail.split(separator: "\n") {
            log(String(line))
        }
    }
}
