//  SettingsView.swift
//  Stamp, quality and PDF options, with a live preview of the stamp.

import SwiftUI
import CoreLocation

struct SettingsView: View {
    /// Current area name, used in the preview.
    let locationName: String?

    @AppStorage(Keys.showDate) private var showDate = true
    @AppStorage(Keys.showTime) private var showTime = true
    @AppStorage(Keys.use24Hour) private var use24Hour = false
    @AppStorage(Keys.saveToPhotos) private var saveToPhotos = true
    @AppStorage(Keys.showLocation) private var showLocation = true
    @AppStorage(Keys.stampPosition) private var position = StampPosition.bottomRight.rawValue
    @AppStorage(Keys.stampSize) private var stampSize = Defaults.stampSize
    @AppStorage(Keys.stampColor) private var stampColor = StampColor.white.rawValue
    @AppStorage(Keys.quality) private var quality = Quality.medium.rawValue
    @AppStorage(Keys.pageSize) private var pageSize = PageSize.photo.rawValue
    @AppStorage(Keys.shareAfterDone) private var shareAfterDone = true
    @AppStorage(Keys.askNameAfterDone) private var askNameAfterDone = true
    @AppStorage(Keys.stampNote) private var stampNote = ""
    @AppStorage(Keys.showCoordinates) private var showCoordinates = false
    @AppStorage(Keys.showHeading) private var showHeading = false
    @AppStorage(Keys.seenCameraTips) private var seenCameraTips = false

    @Environment(\.dismiss) private var dismiss

    private var stampOn: Bool {
        showDate || showTime || showLocation || showCoordinates || showHeading
            || !stampNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var previewLines: [String] {
        _ = (showDate, showTime, use24Hour, showLocation, showCoordinates, showHeading, stampNote)   // refresh on change
        return StampText.lines(date: Date(), place: locationName ?? "Area, Country",
                               coordinate: CLLocationCoordinate2D(latitude: 26.12912, longitude: 50.55503),
                               heading: 225)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    StampPreview(lines: previewLines,
                                 position: StampPosition(rawValue: position) ?? .bottomRight,
                                 size: stampSize,
                                 color: StampColor(rawValue: stampColor) ?? .white)
                        .frame(height: 170)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } footer: {
                    Text("Preview, zoomed in on the corner of a photo.")
                }

                Section {
                    TextField("Note (e.g. project or client name)", text: $stampNote)
                        .onChange(of: stampNote) { _, value in
                            if value.count > Defaults.noteLimit { stampNote = String(value.prefix(Defaults.noteLimit)) }
                        }
                    Toggle("Date", isOn: $showDate)
                    Toggle("Time", isOn: $showTime)
                    Toggle("24-Hour Time", isOn: $use24Hour)
                        .disabled(!showTime)
                    Toggle("Area Name", isOn: $showLocation)
                    Toggle("GPS Coordinates", isOn: $showCoordinates)
                    Toggle("Compass Direction", isOn: $showHeading)
                } header: {
                    Text("On the Photo")
                } footer: {
                    Text("The note is printed on every photo and suggested as the PDF's name. Turn Date and Time on together or on their own. Compass direction shows which way the camera faced (like SW 225°). Stamp settings apply to all photos in the set when you tap Done, even ones you already took.")
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
                    Button {
                        seenCameraTips = false
                        dismiss()
                    } label: {
                        Label("Show Camera Tips", systemImage: "hand.tap")
                    }
                } footer: {
                    Text("Shows the swipe, zoom and focus gestures again.")
                }

                Section {
                    Toggle("Save to Photos", isOn: $saveToPhotos)
                } header: {
                    Text("Photos")
                } footer: {
                    Text("When you tap Done, each photo is also saved with its stamp to the StampCam album in the Photos app. Photos you added from your library aren't saved again.")
                }

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
                         + "Notes you add to photos are printed under them.\n\n"
                         + (askNameAfterDone
                            ? "After Done you can name the PDF, with smart suggestions from the text in your photos. You can always rename later from the folder button."
                            : "PDFs are named by the time of the first photo, like 06.52. You can rename them anytime from the folder button."))
                }

                Section("About") {
                    NavigationLink {
                        AboutView()
                    } label: {
                        HStack {
                            Label("About StampCam", systemImage: "info.circle")
                            Spacer()
                            Text(AppInfo.version).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .tint(.yellow)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Live preview of the stamp, zoomed in on the corner of a sample photo

struct StampPreview: View {
    let lines: [String]
    let position: StampPosition
    let size: Double
    let color: StampColor

    /// The short side of the imaginary photo; the card shows only its corner, so the text is easy to read.
    private let photoShortSide: Double = 370

    var body: some View {
        let fontSize = photoShortSide * size
        ZStack(alignment: position.alignment) {
            LinearGradient(colors: [Color(red: 0.62, green: 0.80, blue: 0.95),
                                    Color(red: 0.93, green: 0.88, blue: 0.78)],
                           startPoint: .top, endPoint: .bottom)
            if lines.isEmpty {
                Text("Nothing on the photo")
                    .font(.footnote)
                    .foregroundStyle(.black.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: fontSize, weight: .bold).monospacedDigit())
                    .multilineTextAlignment(position.isLeft ? .leading : .trailing)
                    .lineSpacing(fontSize * 0.15)
                    .foregroundStyle(color.color)
                    .shadow(color: color.shadow, radius: fontSize * 0.2)
                    .shadow(color: color.shadow, radius: fontSize * 0.2)
                    .padding(fontSize * 0.9)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: position)
    }
}
