//  AboutView.swift
//  About StampCam: version, privacy, what it's built on, and updates.

import SwiftUI

struct AboutView: View {
    private enum UpdateState {
        case idle, checking, upToDate
        case available(Updater.Release)
        case downloading(Updater.Release)
        case failed(String)
    }

    @State private var update: UpdateState = .idle
    @State private var downloaded: URL?
    @State private var copied = false

    var body: some View {
        List {
            header
                .listRowBackground(Color.clear)

            Section {
                updateRow
                if case .available(let release) = update, !release.notes.isEmpty {
                    Text(release.notes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Downloads the new StampCam.ipa. Then open it with your signing app (like Signulous) to install it.")
            }

            Section("Privacy") {
                Label {
                    Text("Everything happens on your iPhone. Nothing is uploaded.")
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(.yellow)
                }

            }

            Section("Powered By") {
                Text("Apple Vision · PDFKit · AVFoundation")

            }

            Section {
                Button {
                    UIPasteboard.general.string = AppInfo.summary
                    Haptics.tap()
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy App Info",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }

            } footer: {
                Text("Copies the version and your iPhone model, handy when reporting a problem.")
            }

            Text("Developed by husain-313")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { downloaded.map(DownloadedFile.init) },
                             set: { if $0 == nil { downloaded = nil } })) { file in
            ShareSheet(url: file.url)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(spacing: 8) {
            Image("AboutIcon")
                .resizable()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            Text("StampCam")
                .font(.title2.bold())
            Text("Version \(AppInfo.version) (\(AppInfo.build))"
                 + (AppInfo.buildDateText.isEmpty ? "" : " · \(AppInfo.buildDateText)"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Stamp your photos with time and place, and turn them into one PDF.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var updateRow: some View {
        switch update {
        case .idle:
            Button { check() } label: {
                Label("Check for Updates", systemImage: "arrow.down.circle")
            }

        case .checking:
            HStack(spacing: 12) {
                ProgressView()
                Text("Checking…").foregroundStyle(.secondary)
            }

        case .upToDate:
            Button { check() } label: {
                Label("You have the latest version", systemImage: "checkmark.circle.fill")
            }

        case .available(let release):
            Button { download(release) } label: {
                Label("Download Version \(release.version)", systemImage: "arrow.down.circle.fill")
                    .bold()
            }

        case .downloading(let release):
            HStack(spacing: 12) {
                ProgressView()
                Text("Downloading \(release.version)…").foregroundStyle(.secondary)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.footnote).foregroundStyle(.red)
                Button("Try Again") { check() }
            }

        }
    }

    // MARK: Actions

    private func check() {
        Haptics.tap()
        update = .checking
        Task {
            do {
                let release = try await Updater.latest()
                update = Updater.isNewer(release.version, than: AppInfo.version) ? .available(release) : .upToDate
            } catch {
                update = .failed(error.localizedDescription)
            }
        }
    }

    private func download(_ release: Updater.Release) {
        Haptics.tap()
        update = .downloading(release)
        Task {
            do {
                let file = try await Updater.download(release)
                update = .available(release)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                downloaded = file
            } catch {
                update = .failed(error.localizedDescription)
            }
        }
    }
}

private struct DownloadedFile: Identifiable {
    let url: URL
    var id: URL { url }
}
