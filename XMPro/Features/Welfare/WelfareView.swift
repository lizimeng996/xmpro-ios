// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// 听时账本与福利任务详情页
@MainActor
struct WelfareView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    @Environment(\.xmPalette) private var palette

    @State private var quota: Quota?
    @State private var ledger: AccountUsageLedger?
    @State private var tasks: [WelfareTask] = []
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        List {
            quotaHeroSection
            ledgerSection
            tasksSection
            if let records = ledger?.records, !records.isEmpty {
                recordsSection(records)
            }
        }
        .listStyle(.insetGrouped)
        .xmPageBackground()
        .xmToast($notice)
        .refreshable {
            await refreshAll()
        }
        .navigationTitle("听时账本与福利")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refreshAll() }
                } label: {
                    if busy {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(busy)
            }
        }
        .task(id: dependencies.accountRevision) {
            await loadLocalState()
        }
    }

    private var quotaHeroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("设备可用听时", systemImage: "hourglass")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let quota {
                        XMTag(text: quota.newDevice ? "新设备" : "标准设备")
                    }
                }

                if let quota {
                    Text(formatDuration(quota.remainingSeconds))
                        .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                } else {
                    Text("尚未查询")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await refreshAll() }
                    } label: {
                        Label("刷新额度", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .xmGlassButton()
                    .disabled(busy)

                    Button {
                        Task { await autoClaim() }
                    } label: {
                        Label("自动领一轮", systemImage: "sparkles")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .xmProminentButton()
                    .disabled(busy)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var ledgerSection: some View {
        Section("当前账号听时账本") {
            if let ledger {
                HStack(spacing: 0) {
                    ledgerStatCell(value: formatDuration(ledger.accumulatedSeconds), label: "累计播放")
                    Divider().frame(height: 28)
                    ledgerStatCell(value: formatDuration(ledger.pendingSeconds), label: "待上报")
                    Divider().frame(height: 28)
                    ledgerStatCell(value: formatDuration(ledger.totalReportedSeconds), label: "已上报")
                }
                .padding(.vertical, 6)

                Button {
                    Task { await reportPending() }
                } label: {
                    HStack {
                        Text(ledger.pendingSeconds > 0
                             ? "立即上报待扣减听时（\(formatDuration(ledger.pendingSeconds))）"
                             : "当前无待上报听时")
                        Spacer()
                        Image(systemName: "arrow.up.circle")
                    }
                }
                .foregroundStyle(ledger.pendingSeconds > 0 ? palette.accent : .secondary)
                .disabled(busy || ledger.pendingSeconds == 0)
            } else {
                Text("请先登录账号查看听时账本统计")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func ledgerStatCell(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var tasksSection: some View {
        Section {
            if tasks.isEmpty {
                Text("暂无可领取任务，下拉或点击右上角刷新拉取最新福利")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tasks) { task in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title)
                                .font(.body.weight(.medium))
                            Text("奖励 \(formatDuration(task.rewardSeconds)) · \(task.status)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if task.claimable {
                            Button("领取") {
                                Task { await claim(task: task) }
                            }
                            .font(.caption.weight(.semibold))
                            .xmProminentButton()
                            .controlSize(.small)
                            .disabled(busy)
                        } else {
                            Text("已领")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text(tasks.isEmpty ? "听时福利任务" : "听时福利任务（\(tasks.count)）")
        }
    }

    private func recordsSection(_ records: [UsageReportRecord]) -> some View {
        Section("近期上报记录") {
            ForEach(records.prefix(15)) { record in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: record.status == .succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(record.status == .succeeded ? Color.green : Color.red)
                            .font(.subheadline)
                        Text("上报 \(formatDuration(record.seconds))")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        if let remaining = record.remainingAfter {
                            Text("余 \(formatDuration(remaining))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !record.message.isEmpty {
                        Text(record.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func loadLocalState() async {
        quota = await dependencies.usageLedger?.cachedDeviceQuota()
        guard let identity = await dependencies.accountStore?.activeAccount()?.identity,
              let usageLedger = dependencies.usageLedger else {
            ledger = nil
            return
        }
        ledger = await usageLedger.snapshot(identity: identity)
    }

    private func refreshAll() async {
        busy = true
        defer { busy = false }

        do {
            let client = try await dependencies.makeCurrentClient()
            if let identity = await dependencies.accountStore?.activeAccount()?.identity,
               let usageLedger = dependencies.usageLedger {
                quota = try await usageLedger.refreshQuota(identity: identity, client: client)
                ledger = await usageLedger.snapshot(identity: identity)
            } else {
                quota = try await client.quota()
            }
            let list = try await dependencies.welfareService.queryTasks()
            tasks = list.tasks
            notice = "已刷新（\(tasks.count) 项任务）"
        } catch let error as XmlyError {
            notice = error.message
        } catch {
            notice = "刷新福利与额度失败，请稍后重试"
        }
    }

    private func claim(task: WelfareTask) async {
        busy = true
        defer { busy = false }

        do {
            let result = try await dependencies.welfareService.claim(task: task)
            notice = result.message
            if result.success {
                await refreshAll()
            }
        } catch let error as XmlyError {
            notice = error.message
        } catch {
            notice = "领取福利失败"
        }
    }

    private func autoClaim() async {
        busy = true
        defer { busy = false }

        guard let identity = await dependencies.accountStore?.activeAccount()?.identity,
              let usageLedger = dependencies.usageLedger else {
            notice = "请先登录账号"
            return
        }
        do {
            let client = try await dependencies.makeCurrentClient()
            let report = await usageLedger.coordinateAutoClaim(
                identity: identity,
                client: client,
                welfare: dependencies.welfareService
            )
            quota = report.finalQuota ?? quota
            ledger = await usageLedger.snapshot(identity: identity)
            notice = "自动领取结束：尝试 \(report.attempts) 次，成功 \(report.succeeded) 次"
        } catch let error as XmlyError {
            notice = error.message
        } catch {
            notice = "自动领取执行失败"
        }
    }

    private func reportPending() async {
        busy = true
        defer { busy = false }

        guard let identity = await dependencies.accountStore?.activeAccount()?.identity,
              let usageLedger = dependencies.usageLedger else {
            notice = "请先登录账号"
            return
        }
        do {
            let client = try await dependencies.makeCurrentClient()
            if let record = await usageLedger.reportPending(identity: identity, client: client) {
                notice = record.status == .succeeded ? "已上报 \(formatDuration(record.seconds))" : record.message
            } else {
                notice = "当前无待上报听时"
            }
            ledger = await usageLedger.snapshot(identity: identity)
            quota = await usageLedger.cachedDeviceQuota() ?? quota
        } catch let error as XmlyError {
            notice = error.message
        } catch {
            notice = "听时上报失败"
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3_600
        let minutes = (clamped % 3_600) / 60
        let secs = clamped % 60
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        if minutes > 0 { return "\(minutes)分\(secs)秒" }
        return "\(secs)秒"
    }
}
