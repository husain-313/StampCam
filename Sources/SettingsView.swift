//  SettingsView.swift
//  Stamp, quality and PDF options, with a live preview of the stamp.

import SwiftUI

struct SettingsView: View {
    /// Current area name, used in the preview.
    let locationName: String?

    @AppStorage(Keys.showTime) private var showTime = true
    @AppStorage(Keys.use24Hour) private var use24Hour = false
    @AppStorage(Keys.showLocation) private var showLocation = true
    @AppStorage(Keys.stampPosition) private var position = StampPosition.bottomRight.rawValue
    @AppStorage(Keys.stampSize) private var stampSize = Defaults.stampSize
    @AppStorage(Keys.stampColor) private var stampColor = StampColor.white.rawValue
    @AppStorage(Keys.quality) private var quality = Quality.medium.rawValue
    @AppStorage(Keys.pageSize) private var pageSize = PageSize.photo.rawValue
    @AppStorage(Keys.shareAfterDone) private var shareAfterDone = true
    @AppStorage(Keys.askNameAfterDone) private var askNameAfterDone = true

    @Environment(\.dismiss) private var dismiss

    private var stampOn: Bool { showTime || showLocation }

    private var previewLines: [String] {
        var lines: [String] = []
        if showTime { lines.append(StampText.time(Date())) }
        if showLocation { lines.append(locationName ?? "Area, Country") }
        return lines
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        StampPreview(lines: previewLines,
                                     position: StampPosition(rawValue: position) ?? .bottomRight,
                                     size: stampSize,
                                     color: StampColor(rawValue: stampColor) ?? .white)
                            .frame(width: 180, height: 240)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    Toggle("Date & Time", isOn: $showTime)
                    Toggle("24-Hour Time", isOn: $use24Hour)
                        .disabled(!showTime)
                    Toggle("Location", isOn: $showLocation)
                } header: {
                    Text("On the Photo")
                } footer: {
                    Text("Stamp settings apply to all photos in the set when you tap Done, even ones you already took.")
                }

                Section("Text") {
                    Picker("Position", selection: $position) {
                        ForEach(StampPosition.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Size")
                            Spacer()
                            Text(verbatim: "\(Int((stampSize / Defaults.stampSize * 100).rounded()))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        HStack {
                            Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                            Slider(value: $stampSize, in: Defaults.stampSizeRange)
                            Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                        }
                    }
                    Picker("Color", selection: $stampColor) {
                        ForEach(StampColor.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                .disabled(!stampOn)

                Section {
                    Picker("Quality", selection: $quality) {
                        ForEach(Quality.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Photo Quality & File Size")
                } footer: {
                    Text((Quality(rawValue: quality) ?? .medium).hint)
                }

                Section {
                    Picker("Page Size", selection: $pageSize) {
                        ForEach(PageSize.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Toggle("Name File After Done", isOn: $askNameAfterDone)
                    Toggle("Share After Done", isOn: $shareAfterDone)
                } header: {
                    Text("PDF")
                } footer: {
                    Text("Fit to Photo: each page has the photo's shape, no margins. A4: standard paper with white margins, best for printing.\n\n"
                         + (askNameAfterDone
                            ? "After Done you can name the PDF, with smart suggestions from the text in your photos. You can always rename later from the folder button."
                            : "PDFs are named by date. You can rename them anytime from the folder button."))
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Live preview of the stamp on a bright sample photo

struct StampPreview: View {
    let lines: [String]
    let position: StampPosition
    let size: Double
    let color: StampColor

    var body: some View {
        GeometryReader { geo in
            let fontSize = geo.size.width * size
            ZStack(alignment: position.alignment) {
                LinearGradient(colors: [Color(red: 0.62, green: 0.80, blue: 0.95),
                                        Color(red: 0.93, green: 0.88, blue: 0.78)],
                               startPoint: .top, endPoint: .bottom)
                if !lines.isEmpty {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(size: fontSize, weight: .bold).monospacedDigit())
                        .multilineTextAlignment(position.isLeft ? .leading : .trailing)
                        .foregroundStyle(color.color)
                        .shadow(color: color.shadow, radius: fontSize * 0.2)
                        .shadow(color: color.shadow, radius: fontSize * 0.2)
                        .padding(fontSize * 0.9)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.easeOut(duration: 0.15), value: position)
    }
}
