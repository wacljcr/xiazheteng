//
//  RuntimePackage.swift
//  MinisApp
//
//  [T-runtime-hub] Catalog + persisted state for the developer Runtime Hub.
//
//  NOTHING is bundled into the app binary. Every runtime is installed on
//  demand from a hosted archive (GitHub repo / release asset provided by the
//  user), verified with real probes, and its state survives restarts via
//  UserDefaults. Packages that also have a workable in-guest install recipe
//  (apk add / git clone) expose that as a fallback mode.
//

import Foundation

// MARK: - Identifiers

enum RuntimeID: String, CaseIterable, Codable, Identifiable {
    // 核心能力
    case codex
    case theos
    // 扩展工具
    case coreTools
    case reverseTools
    case buildTools
    case nodejs
    case python
    case ollvm

    var id: String { rawValue }
}

// MARK: - Category

enum RuntimeCategory: String, Codable {
    /// 核心能力 — the two packages the tweak-dev workflow leans on.
    case core
    /// 扩展工具 — supporting toolchains.
    case extensionTools
}

// MARK: - Install mode

enum RuntimeInstallMode: String, Codable, CaseIterable {
    /// Download a hosted archive (GitHub repo / release asset) and extract it.
    case hosted
    /// In-guest recipe: apk add + post-install shell script.
    case script
}

// MARK: - Probe

struct RuntimeProbe: Sendable {
    let label: String
    let command: String
}

// MARK: - Package model

struct RuntimePackage: Identifiable, Sendable {
    let id: RuntimeID
    let name: String
    let subtitle: String
    let category: RuntimeCategory
    let symbolName: String
    /// SwiftUI color name used for the icon badge.
    let colorName: String
    /// Alpine packages installed via `apk add` before any post-install script.
    /// Empty when the package has no in-guest fallback recipe.
    let apkPackages: [String]
    /// Packages that must be `ready` before this one may install.
    let dependsOn: [RuntimeID]
    /// Shell script executed inside the guest after the apk step (script mode).
    /// Must be /bin/sh (ash) compatible. Empty = hosted-only package.
    let postInstallScript: String
    /// Commands run after install; each must exit 0 for the install to count.
    let probes: [RuntimeProbe]

    var installSizeHint: String

    /// Hosted mode is always available once the user provides the archive URL;
    /// script mode only when a recipe exists.
    var supportsScriptFallback: Bool {
        !apkPackages.isEmpty || !postInstallScript.isEmpty
    }
}

// MARK: - Status

enum RuntimeStatus: String, Codable {
    case notInstalled
    case installing
    case installed
}

struct RuntimeState: Codable {
    var status: RuntimeStatus = .notInstalled
    var version: String?
    var installedAt: Date?
    var lastProbeError: String?
}

// MARK: - Catalog

enum RuntimeCatalog {

    static let all: [RuntimePackage] = [
        RuntimePackage(
            id: .codex,
            name: "Codex",
            subtitle: "Agent CLI 运行时",
            category: .core,
            symbolName: "chevron.left.forwardslash.chevron.right",
            colorName: "blue",
            apkPackages: [],
            dependsOn: [.nodejs],
            postInstallScript: """
            set -e
            echo "[codex] npm 全局安装 @openai/codex"
            npm install -g @openai/codex --no-audit --no-fund 2>&1 | tail -n 3
            """,
            probes: [RuntimeProbe(label: "codex", command: "codex --version 2>&1 | head -n 1")],
            installSizeHint: "≈ 108 MB"
        ),
        RuntimePackage(
            id: .theos,
            name: "Theos",
            subtitle: "iOS 编译、链接、签名、DEB",
            category: .core,
            symbolName: "hammer.fill",
            colorName: "orange",
            apkPackages: ["make", "clang", "lld", "perl", "git", "ca-certificates", "tar", "gzip", "findutils"],
            dependsOn: [],
            postInstallScript: """
            set -e
            if ! command -v ldid >/dev/null 2>&1; then
              echo "[theos] 获取 ldid"
              if ! apk add --no-cache ldid 2>/dev/null; then
                apk add --no-cache build-base
                rm -rf /tmp/ldid-src
                git clone --depth 1 https://github.com/ProcursusTeam/ldid.git /tmp/ldid-src 2>&1 | tail -n 1
                make -C /tmp/ldid-src -j2 2>&1 | tail -n 2
                install -m 0755 /tmp/ldid-src/ldid /usr/local/bin/ldid
                rm -rf /tmp/ldid-src
              fi
            fi
            echo "[theos] 克隆 theos 主仓库（--recursive）"
            git clone --recursive --depth 1 https://github.com/theos/theos.git /opt/theos 2>&1 | tail -n 3
            echo "[theos] 拉取 iOS SDK（体积较大，耐心等待）"
            rm -rf /tmp/theos-sdks
            git clone --depth 1 https://github.com/theos/sdks.git /tmp/theos-sdks 2>&1 | tail -n 1
            mkdir -p /opt/theos/sdks
            for d in /tmp/theos-sdks/iPhoneOS*.sdk; do
              [ -d "$d" ] && mv "$d" /opt/theos/sdks/ || true
            done
            rm -rf /tmp/theos-sdks
            echo "[theos] 可用 SDK:"
            ls /opt/theos/sdks 2>/dev/null | sed 's/^/  - /'
            grep -q 'THEOS=' /root/.profile 2>/dev/null || \\
              printf '\\nexport THEOS=/opt/theos\\nexport PATH=$THEOS/bin:$PATH\\n' >> /root/.profile
            echo "[theos] 完成：THEOS=/opt/theos"
            """,
            probes: [
                RuntimeProbe(label: "clang", command: "clang --version 2>&1 | head -n 1"),
                RuntimeProbe(label: "theos", command: "test -d /opt/theos/include && echo /opt/theos"),
                RuntimeProbe(label: "ldid", command: "command -v ldid"),
            ],
            installSizeHint: "≈ 1–2 GB（含 iOS SDK）"
        ),
        RuntimePackage(
            id: .coreTools,
            name: "CoreTools",
            subtitle: "git / rg / curl / jq 等基础件",
            category: .extensionTools,
            symbolName: "shippingbox.fill",
            colorName: "teal",
            apkPackages: ["git", "ripgrep", "curl", "jq", "openssh-client", "less"],
            dependsOn: [],
            postInstallScript: "",
            probes: [
                RuntimeProbe(label: "git", command: "git --version 2>&1 | head -n 1"),
                RuntimeProbe(label: "rg", command: "rg --version 2>&1 | head -n 1"),
            ],
            installSizeHint: "≈ 81 MB"
        ),
        RuntimePackage(
            id: .reverseTools,
            name: "ReverseTools",
            subtitle: "radare2 / Mach-O 静态分析",
            category: .extensionTools,
            symbolName: "wrench.and.screwdriver.fill",
            colorName: "purple",
            apkPackages: ["radare2"],
            dependsOn: [],
            postInstallScript: "",
            probes: [RuntimeProbe(label: "r2", command: "r2 -v 2>&1 | head -n 1")],
            installSizeHint: "≈ 42 MB"
        ),
        RuntimePackage(
            id: .buildTools,
            name: "BuildTools",
            subtitle: "CMake / Ninja / Make",
            category: .extensionTools,
            symbolName: "gauge.with.needle.fill",
            colorName: "indigo",
            apkPackages: ["cmake", "ninja", "make"],
            dependsOn: [],
            postInstallScript: "",
            probes: [
                RuntimeProbe(label: "cmake", command: "cmake --version 2>&1 | head -n 1"),
                RuntimeProbe(label: "ninja", command: "ninja --version 2>&1 | head -n 1"),
            ],
            installSizeHint: "≈ 126 MB"
        ),
        RuntimePackage(
            id: .nodejs,
            name: "Node.js",
            subtitle: "node / npm / npx",
            category: .extensionTools,
            symbolName: "hexagon.fill",
            colorName: "green",
            apkPackages: ["nodejs", "npm"],
            dependsOn: [],
            postInstallScript: "",
            probes: [RuntimeProbe(label: "node", command: "node --version 2>&1 | head -n 1")],
            installSizeHint: "≈ 50 MB"
        ),
        RuntimePackage(
            id: .python,
            name: "Python",
            subtitle: "python3 / pip",
            category: .extensionTools,
            symbolName: "circle.fill",
            colorName: "blue",
            apkPackages: ["python3", "py3-pip"],
            dependsOn: [],
            postInstallScript: "",
            probes: [RuntimeProbe(label: "python3", command: "python3 --version 2>&1 | head -n 1")],
            installSizeHint: "≈ 70 MB"
        ),
        RuntimePackage(
            id: .ollvm,
            name: "OLLVM",
            subtitle: "编译混淆",
            category: .extensionTools,
            symbolName: "f.circle.fill",
            colorName: "purple",
            apkPackages: [],
            dependsOn: [],
            postInstallScript: "",
            probes: [RuntimeProbe(label: "ollvm", command: "test -x /opt/ollvm/bin/clang || test -d /opt/ollvm && echo /opt/ollvm")],
            installSizeHint: "视包而定"
        ),
    ]

    static func package(_ id: RuntimeID) -> RuntimePackage {
        guard let pkg = all.first(where: { $0.id == id }) else {
            fatalError("Unknown runtime id: \(id)")
        }
        return pkg
    }

    static var core: [RuntimePackage] { all.filter { $0.category == .core } }
    static var extensions: [RuntimePackage] { all.filter { $0.category == .extensionTools } }
}

// MARK: - Persistence

enum RuntimeStateStore {

    private static let prefix = "runtimehub.state."
    private static let defaults = UserDefaults.standard

    static func state(for id: RuntimeID) -> RuntimeState {
        guard let data = defaults.data(forKey: prefix + id.rawValue),
              let state = try? JSONDecoder().decode(RuntimeState.self, from: data)
        else { return RuntimeState() }
        return state
    }

    static func setState(_ state: RuntimeState, for id: RuntimeID) {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: prefix + id.rawValue)
        }
    }

    // Hosted package settings — the archive URL the user provides for each
    // runtime (GitHub repo / release asset). SHA-256 is optional.
    static func hostedURL(for id: RuntimeID) -> String {
        defaults.string(forKey: "runtimehub.hostedURL.\(id.rawValue)") ?? ""
    }

    static func setHostedURL(_ url: String, for id: RuntimeID) {
        defaults.set(url, forKey: "runtimehub.hostedURL.\(id.rawValue)")
    }

    static func hostedSHA256(for id: RuntimeID) -> String {
        defaults.string(forKey: "runtimehub.hostedSHA.\(id.rawValue)") ?? ""
    }

    static func setHostedSHA256(_ sha: String, for id: RuntimeID) {
        defaults.set(sha, forKey: "runtimehub.hostedSHA.\(id.rawValue)")
    }
}
