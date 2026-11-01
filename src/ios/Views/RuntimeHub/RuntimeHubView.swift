//
//  RuntimeHubView.swift
//  MinisApp
//
//  [T-runtime-hub] Developer Runtime Hub — 核心能力 / 扩展工具 two-section
//  package manager. Nothing is bundled: every runtime is fetched on demand
//  from a user-provided GitHub archive, probed after install, and rolled back
//  on failure.
//

import SwiftUI

// MARK: - Entry

struct RuntimeHubView: View {
    @StateObject private var viewModel = RuntimeHubViewModel()

    var body: some View {
        Group {
            if viewModel.sandboxBooted {
                hubList
            } else {
                bootPlaceholder
                    .onAppear { viewModel.ensureSandboxBooted() }
            }
        }
        .navigationTitle("开发环境")
        .onAppear { viewModel.refresh() }
        .alert(
            "安装出错",
            isPresented: .init(
                get: { viewModel.lastError != nil },
                set: { if !$0 { viewModel.lastError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.lastError ?? "")
        }
    }

    // MARK: Sections

    private var hubList: some View {
        List {
            Section("核心能力") {
                ForEach(RuntimeCatalog.core) { package in
                    row(for: package)
                }
            }
            Section("扩展工具") {
                ForEach(RuntimeCatalog.extensions) { package in
                    row(for: package)
                }
            }
            Section {
                Text("所有工具包不随 App 内置：安装时从你提供的 GitHub 仓库 / Release 附件下载到手机上的 Linux 沙盒，安装后自动探针验证，失败自动回滚。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var bootPlaceholder: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(viewModel.bootMessage ?? "正在启动 Linux 沙盒…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Row

    @ViewBuilder
    private func row(for package: RuntimePackage) -> some View {
        NavigationLink {
            RuntimeDetailPage(package: package, viewModel: viewModel)
        } label: {
            HStack(spacing: 12) {
                RuntimeIconBadge(symbolName: package.symbolName, colorName: package.colorName)

                VStack(alignment: .leading, spacing: 3) {
                    Text(package.name)
                        .font(.body.weight(.medium))
                    Text(statusText(for: package.id))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if viewModel.installingID == package.id {
                    ProgressView()
                }
            }
        }
    }

    private func statusText(for id: RuntimeID) -> String {
        let state = viewModel.states[id] ?? RuntimeState()
        switch state.status {
        case .installed:
            return state.version ?? "已就绪"
        case .installing:
            return "安装中…"
        case .notInstalled:
            return viewModel.hasHostedConfig(id) ? "未安装" : "当前包未内置"
        }
    }
}

// MARK: - Icon badge

struct RuntimeIconBadge: View {
    let symbolName: String
    let colorName: String

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(badgeColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var badgeColor: Color {
        switch colorName {
        case "blue": return .blue
        case "orange": return .orange
        case "teal": return .teal
        case "purple": return .purple
        case "indigo": return .indigo
        case "green": return .green
        default: return .gray
        }
    }
}

// MARK: - Detail page

struct RuntimeDetailPage: View {
    let package: RuntimePackage
    @ObservedObject var viewModel: RuntimeHubViewModel

    @State private var mode: RuntimeInstallMode = .hosted
    @State private var hostedURL: String = RuntimeStateStore.hostedURL(for: .codex)
    @State private var hostedSHA: String = ""
    @State private var showUninstallConfirm = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    RuntimeIconBadge(symbolName: package.symbolName, colorName: package.colorName)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(package.name).font(.headline)
                        Text(package.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)

                LabeledContent("预估体积", value: package.installSizeHint)

                if let state = viewModel.states[package.id], state.status == .installed {
                    LabeledContent("版本", value: state.version ?? "已就绪")
                }
            }

            // 依赖提示
            if !package.dependsOn.isEmpty {
                Section("依赖") {
                    ForEach(package.dependsOn) { dep in
                        let depState = viewModel.states[dep] ?? RuntimeState()
                        HStack {
                            Text(RuntimeCatalog.package(dep).name)
                            Spacer()
                            Text(depState.status == .installed ? "已就绪" : "未安装")
                                .font(.caption)
                                .foregroundStyle(depState.status == .installed ? Color.green : Color.orange)
                        }
                    }
                }
            }

            // 安装源配置
            Section {
                Picker("安装方式", selection: $mode) {
                    Text("托管包（GitHub）").tag(RuntimeInstallMode.hosted)
                    if package.supportsScriptFallback {
                        Text("内置脚本").tag(RuntimeInstallMode.script)
                    }
                }
                .pickerStyle(.segmented)

                if mode == .hosted {
                    TextField("https://github.com/.../pkg.tar.gz", text: $hostedURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("SHA-256（可选）", text: $hostedSHA)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    Text("将使用沙盒内的 apk / 安装脚本安装（\(package.apkPackages.joined(separator: ", "))）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("安装源")
            } footer: {
                if mode == .hosted {
                    Text("把该工具打包成 tar / tar.gz / tar.xz 上传到你的 GitHub 仓库或 Release，把直链填到上面；SHA-256 可选（用于校验）。App 不内置任何工具包。")
                }
            }

            // 操作
            Section {
                let busy = viewModel.installingID != nil
                Button {
                    viewModel.saveHostedConfig(package: package, url: hostedURL, sha: hostedSHA)
                    viewModel.install(package, mode: mode)
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.installingID == package.id {
                            ProgressView().padding(.trailing, 6)
                            Text("安装中…")
                        } else {
                            Text(installButtonTitle)
                        }
                        Spacer()
                    }
                }
                .disabled(busy || !installButtonEnabled)

                if (viewModel.states[package.id]?.status ?? .notInstalled) == .installed {
                    Button(role: .destructive) {
                        showUninstallConfirm = true
                    } label: {
                        HStack { Spacer(); Text("卸载"); Spacer() }
                    }
                    .disabled(busy)
                }
            }

            // 日志
            if viewModel.installingID == package.id, !viewModel.activeLog.isEmpty {
                Section("安装日志") {
                    ForEach(Array(viewModel.activeLog.suffix(40).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
        }
        .navigationTitle(package.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            hostedURL = RuntimeStateStore.hostedURL(for: package.id)
            hostedSHA = RuntimeStateStore.hostedSHA256(for: package.id)
        }
        .confirmationDialog("卸载 \(package.name)？", isPresented: $showUninstallConfirm, titleVisibility: .visible) {
            Button("卸载", role: .destructive) {
                viewModel.uninstall(package)
            }
        }
    }

    private var installButtonTitle: String {
        if (viewModel.states[package.id]?.status ?? .notInstalled) == .installed {
            return "重新安装"
        }
        return mode == .hosted ? "安装" : "用内置脚本安装"
    }

    private var installButtonEnabled: Bool {
        if mode == .hosted {
            return viewModel.hasHostedConfig(package.id) || hostedURL.hasPrefix("http")
        }
        return package.supportsScriptFallback
    }
}
