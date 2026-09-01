import SwiftUI
import CoreGraphics

private enum PreferencesKeys {
    static let screenshotSaveFolder = "screenshotSaveFolder"
    static let screenshotSaveFolderBookmark = "screenshotSaveFolderBookmark"
}

struct PreferencesView: View {
    @State private var selectedTab = 0
    
    private static let contentPadding: CGFloat = 24
    private static let windowWidth: CGFloat = 528  // 10% wider than 480
    private static let windowHeight: CGFloat = 580
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab bar at the top
            HStack(spacing: 0) {
                TabButton(title: "General", isSelected: selectedTab == 0) { selectedTab = 0 }
                TabButton(title: "Clipboard", isSelected: selectedTab == 1) { selectedTab = 1 }
                TabButton(title: "Shortcuts", isSelected: selectedTab == 2) { selectedTab = 2 }
                TabButton(title: "About", isSelected: selectedTab == 3) { selectedTab = 3 }
            }
            .padding(.horizontal, Self.contentPadding)
            .padding(.top, 12)
            
            Divider()
                .padding(.top, 12)
            
            // Content — tap outside input fields to unfocus
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedTab {
                    case 0: BehaviorTab()
                    case 1: ClipboardHistoryTab()
                    case 2: ShortcutsTab()
                    case 3: AboutTab()
                    default: EmptyView()
                    }
                }
                .frame(minWidth: Self.windowWidth - 2 * Self.contentPadding, maxWidth: .infinity, alignment: .leading)
                .padding(Self.contentPadding)
                .padding(.bottom, Self.contentPadding)
                .contentShape(Rectangle())
                .onTapGesture {
                    if NSApp.keyWindow?.firstResponder is ShortcutTextField {
                        return
                    }
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: Self.windowWidth, height: Self.windowHeight)
    }
}

struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .primary : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Behavior Tab

struct BehaviorTab: View {
    private static let toolSizeMin = 40
    private static let toolSizeMax = 800

    @AppStorage("launchOnLogin") private var launchOnLogin = false
    @AppStorage("recordingDictationSubtitles") private var recordingDictationSubtitles = true
    @AppStorage("recordingMicrophoneAudio") private var recordingMicrophoneAudio = false
    @AppStorage("subtitleColorRed") private var subtitleColorRed = 0.0
    @AppStorage("subtitleColorGreen") private var subtitleColorGreen = 0.0
    @AppStorage("subtitleColorBlue") private var subtitleColorBlue = 0.0
    @AppStorage("subtitleColorAlpha") private var subtitleColorAlpha = 1.0
    @AppStorage("subtitleSizeScale") private var subtitleSizeScale = 1.0
    @State private var subtitleColor: Color = .black
    // Note: auto-paste ("inputCmdV") lives in the Clipboard tab's "Auto Paste" section.
    @AppStorage("playNotificationSounds") private var playNotificationSounds = true
    @AppStorage("showToastNotifications") private var showToastNotifications = true
    @AppStorage("magnifyingGlassSize") private var magnifyingGlassSize = 160
    @AppStorage("haloSize") private var haloSize = 160
    @AppStorage("colorPickerSize") private var colorPickerSize = 160
    @AppStorage("haloColorRed") private var haloColorRed = 1.0
    @AppStorage("haloColorGreen") private var haloColorGreen = 1.0
    @AppStorage("haloColorBlue") private var haloColorBlue = 1.0
    @AppStorage("haloColorAlpha") private var haloColorAlpha = 1.0
    @AppStorage("brushColorMode") private var brushColorMode = "mono"
    @AppStorage("brushColorRed") private var brushColorRed = 1.0
    @AppStorage("brushColorGreen") private var brushColorGreen = 0.0
    @AppStorage("brushColorBlue") private var brushColorBlue = 0.0
    @AppStorage("brushColorAlpha") private var brushColorAlpha = 1.0
    @AppStorage("screenshotAnnotationFont") private var screenshotAnnotationFont = "Helvetica"
    @AppStorage("saveScreenshotsToFolder") private var saveScreenshotsToFolder = false
    
    @State private var haloColor: Color = .white
    @State private var brushColor: Color = .black
    @State private var screenshotFolderPath: String = ""
    @State private var recordingFolderPath: String = ""
    @State private var launchAtLoginError: String? = nil
    @State private var magnifyingGlassSizeError: String? = nil
    @State private var haloSizeError: String? = nil
    @State private var colorPickerSizeError: String? = nil
    @FocusState private var magnifyingGlassSizeFocused: Bool
    @FocusState private var haloSizeFocused: Bool
    @FocusState private var colorPickerSizeFocused: Bool
    
    private var annotationFontList: [String] {
        let available = NSFontManager.shared.availableFontFamilies.sorted()
        let common = ["Helvetica", "Arial", "Times New Roman", "Courier New", "Verdana", "Georgia", "Palatino", "Monaco", "Menlo"]
        var list = common.filter { available.contains($0) }
        list.append(contentsOf: available.filter { !common.contains($0) })
        if !list.contains(screenshotAnnotationFont) {
            list.insert(screenshotAnnotationFont, at: 0)
        }
        return list
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Behavior")

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Launch on Login", isOn: $launchOnLogin)
                    .onChange(of: launchOnLogin) { _, newValue in
                        do {
                            try LoginItemManager.setLaunchAtLogin(newValue)
                        } catch {
                            launchOnLogin = !newValue
                            launchAtLoginError = error.localizedDescription
                        }
                    }
                Toggle("Play notification sounds", isOn: $playNotificationSounds)
                Toggle("Show toast notifications", isOn: $showToastNotifications)
            }
            
            Divider()
                .padding(.vertical, 8)
            
            SectionHeader(title: "Tool Sizes")
            
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRow(label: "Magnifying Glass:") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Spacer(minLength: 8)
                            TextField("", value: $magnifyingGlassSize, format: .number)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                                .focused($magnifyingGlassSizeFocused)
                                .onChange(of: magnifyingGlassSizeFocused) { _, focused in
                                    if !focused { validateMagnifyingGlassSize(magnifyingGlassSize) }
                                }
                            Text("px")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .frame(minWidth: 0, maxWidth: .infinity)
                    }
                    if let message = magnifyingGlassSizeError {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRow(label: "Halo:") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Spacer(minLength: 8)
                            TextField("", value: $haloSize, format: .number)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                                .focused($haloSizeFocused)
                                .onChange(of: haloSizeFocused) { _, focused in
                                    if !focused { validateHaloSize(haloSize) }
                                }
                            Text("px")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .frame(minWidth: 0, maxWidth: .infinity)
                    }
                    if let message = haloSizeError {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRow(label: "Color Picker:") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Spacer(minLength: 8)
                            TextField("", value: $colorPickerSize, format: .number)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                                .focused($colorPickerSizeFocused)
                                .onChange(of: colorPickerSizeFocused) { _, focused in
                                    if !focused { validateColorPickerSize(colorPickerSize) }
                                }
                            Text("px")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .frame(minWidth: 0, maxWidth: .infinity)
                    }
                    if let message = colorPickerSizeError {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            
            Divider()
                .padding(.vertical, 8)
            
            SectionHeader(title: "Annotation Colour")

            VStack(alignment: .leading, spacing: 12) {
                SettingsRow(label: "Default colour mode:") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Spacer(minLength: 8)
                        Picker("", selection: $brushColorMode) {
                            Text("Rainbow").tag("rainbow")
                            Text("Mono").tag("mono")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140, alignment: .trailing)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                }
                
                if brushColorMode == "mono" {
                    SettingsRow(label: "Color:") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Spacer(minLength: 8)
                            ColorPicker("", selection: $brushColor)
                                .labelsHidden()
                                .onChange(of: brushColor) { _, newColor in
                                    // Convert SwiftUI Color to NSColor and save
                                    let nsColor = NSColor(newColor)
                                    if let rgb = nsColor.usingColorSpace(.sRGB) {
                                        brushColorRed = Double(rgb.redComponent)
                                        brushColorGreen = Double(rgb.greenComponent)
                                        brushColorBlue = Double(rgb.blueComponent)
                                        brushColorAlpha = Double(rgb.alphaComponent)
                                    }
                                }
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            
            Divider()
                .padding(.vertical, 8)
            
            SectionHeader(title: "Halo Color")
            
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Color:")
                        .frame(width: 180, alignment: .leading)
                    Spacer(minLength: 12)
                    ColorPicker("", selection: $haloColor)
                        .labelsHidden()
                        .onChange(of: haloColor) { _, newColor in
                            // Convert SwiftUI Color to NSColor and save
                            let nsColor = NSColor(newColor)
                            if let rgb = nsColor.usingColorSpace(.sRGB) {
                                haloColorRed = Double(rgb.redComponent)
                                haloColorGreen = Double(rgb.greenComponent)
                                haloColorBlue = Double(rgb.blueComponent)
                                haloColorAlpha = Double(rgb.alphaComponent)
                            }
                        }
                }
            }
            
            Divider()
                .padding(.vertical, 8)
            
            SectionHeader(title: "Screenshot")
            
            VStack(alignment: .leading, spacing: 12) {
                SettingsRow(label: "Annotation font:") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Spacer(minLength: 8)
                        Picker("", selection: $screenshotAnnotationFont) {
                            ForEach(annotationFontList, id: \.self) { font in
                                Text(font).tag(font)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140, alignment: .trailing)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                }
                
                Toggle("Save screenshots to folder:", isOn: $saveScreenshotsToFolder)
                
                if saveScreenshotsToFolder {
                    SettingsRow(label: "Folder:") {
                        HStack(spacing: 8) {
                            if !screenshotFolderPath.isEmpty {
                                Text(screenshotFolderPath)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            }
                            Button("Choose...") {
                                chooseScreenshotFolder()
                            }
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }

            Divider()
                .padding(.vertical, 8)

            SectionHeader(title: "Screen Recording")

            VStack(alignment: .leading, spacing: 12) {
                SettingsRow(label: "Save recordings to:") {
                    HStack(spacing: 8) {
                        Text(recordingFolderPath.isEmpty ? "Desktop (asks once on first recording)" : recordingFolderPath)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        Button("Choose...") {
                            chooseRecordingFolder()
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                }

                Text("Recordings are saved as timestamped .mov files. They are not copied to the clipboard.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Dictate subtitles", isOn: $recordingDictationSubtitles)
                    .onChange(of: recordingDictationSubtitles) { _, enabled in
                        if enabled { AppDelegate.preflightCaptionAssetsIfNeeded() }
                    }

                if recordingDictationSubtitles {
                    SettingsRow(label: "Subtitle size:") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Spacer(minLength: 8)
                            Picker("", selection: $subtitleSizeScale) {
                                ForEach(CaptionRenderMetrics.sizeOptions, id: \.scale) { option in
                                    Text(option.label).tag(option.scale)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 140, alignment: .trailing)
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                    }

                    SettingsRow(label: "Subtitle color:") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Spacer(minLength: 8)
                            ColorPicker("", selection: $subtitleColor)
                                .labelsHidden()
                                .onChange(of: subtitleColor) { _, newColor in
                                    let nsColor = NSColor(newColor)
                                    if let rgb = nsColor.usingColorSpace(.sRGB) {
                                        subtitleColorRed = Double(rgb.redComponent)
                                        subtitleColorGreen = Double(rgb.greenComponent)
                                        subtitleColorBlue = Double(rgb.blueComponent)
                                        subtitleColorAlpha = Double(rgb.alphaComponent)
                                    }
                                }
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                    }
                }

                // Extra top gap: without it this peer option reads as another subtitle
                // sub-setting, since those sit at the same indent.
                Toggle("Record microphone audio", isOn: $recordingMicrophoneAudio)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            launchOnLogin = LoginItemManager.isRegistered
            clampToolSizes()
            // Load current halo color from preferences
            let nsColor = NSColor(
                red: CGFloat(haloColorRed),
                green: CGFloat(haloColorGreen),
                blue: CGFloat(haloColorBlue),
                alpha: CGFloat(haloColorAlpha > 0 ? haloColorAlpha : 1.0)
            )
            haloColor = Color(nsColor)
            
            // Load current brush color from preferences
            let brushNsColor = NSColor(
                red: CGFloat(brushColorRed),
                green: CGFloat(brushColorGreen),
                blue: CGFloat(brushColorBlue),
                alpha: CGFloat(brushColorAlpha > 0 ? brushColorAlpha : 1.0)
            )
            brushColor = Color(brushNsColor)
            
            // Load screenshot folder path
            screenshotFolderPath = displayPathForScreenshotFolder()

            // Load recording folder path
            recordingFolderPath = displayPathForRecordingFolder()

            // Load current subtitle colour from preferences
            subtitleColor = Color(NSColor(
                srgbRed: CGFloat(subtitleColorRed),
                green: CGFloat(subtitleColorGreen),
                blue: CGFloat(subtitleColorBlue),
                alpha: CGFloat(subtitleColorAlpha > 0 ? subtitleColorAlpha : 1.0)
            ))
        }
        .alert("Launch on Login", isPresented: Binding(
            get: { launchAtLoginError != nil },
            set: { if !$0 { launchAtLoginError = nil } }
        )) {
            Button("OK") { launchAtLoginError = nil }
        } message: {
            Text(launchAtLoginError ?? "")
        }
    }
    
    private func setErrorTemporary(_ binding: Binding<String?>, _ value: String?) {
        binding.wrappedValue = value
        if value != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                binding.wrappedValue = nil
            }
        }
    }

    private func clampToolSizes() {
        let (minV, maxV) = (Self.toolSizeMin, Self.toolSizeMax)
        if magnifyingGlassSize < minV || magnifyingGlassSize > maxV {
            magnifyingGlassSize = min(maxV, max(minV, magnifyingGlassSize))
        }
        if haloSize < minV || haloSize > maxV {
            haloSize = min(maxV, max(minV, haloSize))
        }
        if colorPickerSize < minV || colorPickerSize > maxV {
            colorPickerSize = min(maxV, max(minV, colorPickerSize))
        }
    }

    private func validateMagnifyingGlassSize(_ value: Int) {
        let (minV, maxV) = (Self.toolSizeMin, Self.toolSizeMax)
        if value > maxV {
            magnifyingGlassSize = maxV
            setErrorTemporary($magnifyingGlassSizeError, "Value must be between \(minV) and \(maxV) px.")
        } else if value < minV {
            magnifyingGlassSize = minV
            setErrorTemporary($magnifyingGlassSizeError, "Value must be between \(minV) and \(maxV) px.")
        } else {
            magnifyingGlassSizeError = nil
        }
    }

    private func validateHaloSize(_ value: Int) {
        let (minV, maxV) = (Self.toolSizeMin, Self.toolSizeMax)
        if value > maxV {
            haloSize = maxV
            setErrorTemporary($haloSizeError, "Value must be between \(minV) and \(maxV) px.")
        } else if value < minV {
            haloSize = minV
            setErrorTemporary($haloSizeError, "Value must be between \(minV) and \(maxV) px.")
        } else {
            haloSizeError = nil
        }
    }

    private func validateColorPickerSize(_ value: Int) {
        let (minV, maxV) = (Self.toolSizeMin, Self.toolSizeMax)
        if value > maxV {
            colorPickerSize = maxV
            setErrorTemporary($colorPickerSizeError, "Value must be between \(minV) and \(maxV) px.")
        } else if value < minV {
            colorPickerSize = minV
            setErrorTemporary($colorPickerSizeError, "Value must be between \(minV) and \(maxV) px.")
        } else {
            colorPickerSizeError = nil
        }
    }

    private func chooseScreenshotFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Screenshot Save Folder"
        panel.prompt = "Choose"

        if !screenshotFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: screenshotFolderPath, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        if let bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmarkData, forKey: PreferencesKeys.screenshotSaveFolderBookmark)
        }
        UserDefaults.standard.set(url.path, forKey: PreferencesKeys.screenshotSaveFolder)
        screenshotFolderPath = url.path
    }

    private func displayPathForScreenshotFolder() -> String {
        if let data = UserDefaults.standard.data(forKey: PreferencesKeys.screenshotSaveFolderBookmark) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url.path
            }
        }
        return UserDefaults.standard.string(forKey: PreferencesKeys.screenshotSaveFolder) ?? ""
    }

    private func chooseRecordingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Recording Save Folder"
        panel.prompt = "Choose"

        if !recordingFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: recordingFolderPath, isDirectory: true)
        } else {
            panel.directoryURL = RecordingDestination.realDesktopURL()
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        RecordingDestination.store(folderURL: url)
        recordingFolderPath = url.path
    }

    private func displayPathForRecordingFolder() -> String {
        if let data = UserDefaults.standard.data(forKey: RecordingDestinationKeys.folderBookmark) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url.path
            }
        }
        return UserDefaults.standard.string(forKey: RecordingDestinationKeys.folder) ?? ""
    }
}

// MARK: - Clipboard History Tab

/// Toggle + frequency controls for the optional scheduled clearing of clipboard history.
/// Changes are persisted via `@AppStorage` and pushed to the running `ClipboardManager`
/// so its timer re-arms immediately.
struct AutoClearHistorySection: View {
    @AppStorage(ClipboardManager.AutoClearKeys.enabled) private var enabled = false
    @AppStorage(ClipboardManager.AutoClearKeys.mode) private var mode = "daily"
    @AppStorage(ClipboardManager.AutoClearKeys.intervalValue) private var intervalValue = 1
    @AppStorage(ClipboardManager.AutoClearKeys.intervalUnit) private var intervalUnit = "days"
    @AppStorage(ClipboardManager.AutoClearKeys.hour) private var hour = 3
    @AppStorage(ClipboardManager.AutoClearKeys.minute) private var minute = 0
    @AppStorage(ClipboardManager.AutoClearKeys.weekday) private var weekday = 2

    /// Calendar weekday (1 = Sunday … 7 = Saturday) paired with its localized name.
    private static let weekdayChoices: [(Int, String)] = {
        let names = DateFormatter().standaloneWeekdaySymbols
            ?? ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return Array(zip(1...7, names))
    }()

    /// Bridges the stored hour/minute integers to the `Date` a `DatePicker` expects.
    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: min(23, max(0, hour)),
                    minute: min(59, max(0, minute)),
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                hour = comps.hour ?? 0
                minute = comps.minute ?? 0
                applyChange()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Automatically clear history", isOn: $enabled)
                .onChange(of: enabled) { applyChange() }

            if enabled {
                Picker("Schedule", selection: $mode) {
                    Text("Every…").tag("interval")
                    Text("Daily").tag("daily")
                    Text("Weekly").tag("weekly")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: mode) { applyChange() }

                switch mode {
                case "interval":
                    HStack(spacing: 8) {
                        Text("Every")
                        TextField("", value: $intervalValue, format: .number)
                            .frame(width: 50)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: intervalValue) { _, newValue in
                                if newValue < 1 { intervalValue = 1 }
                                applyChange()
                            }
                        Picker("", selection: $intervalUnit) {
                            Text("hours").tag("hours")
                            Text("days").tag("days")
                            Text("weeks").tag("weeks")
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        .onChange(of: intervalUnit) { applyChange() }
                    }
                case "weekly":
                    HStack(spacing: 8) {
                        Text("On")
                        Picker("", selection: $weekday) {
                            ForEach(Self.weekdayChoices, id: \.0) { day in
                                Text(day.1).tag(day.0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .onChange(of: weekday) { applyChange() }
                        Text("at")
                        DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                default: // daily
                    HStack(spacing: 8) {
                        Text("At")
                        DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                }

                Text(scheduleDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var scheduleDescription: String {
        switch mode {
        case "interval":
            let unit = intervalValue == 1 ? String(intervalUnit.dropLast()) : intervalUnit
            return "History is cleared every \(max(1, intervalValue)) \(unit)."
        case "weekly":
            let name = Self.weekdayChoices.first(where: { $0.0 == weekday })?.1 ?? "the chosen day"
            return "History is cleared every \(name) at the chosen time."
        default:
            return "History is cleared every day at the chosen time."
        }
    }

    private func applyChange() {
        ClipboardManager.shared.refreshAutoClearSchedule()
    }
}

#if ALLOW_AUTOPASTE
/// Live PostEvent (auto-paste ⌘V) permission state that drives the Auto Paste banner and the
/// revoke-triggered auto-off of the toggle. Backed by `PermissionManager.probePostEventAccessLive`
/// (a fresh-process probe) because the in-process `CGPreflightPostEventAccess()` cache is stale
/// mid-session and cannot be trusted for an accurate green/red indicator.
final class AutoPastePermissionMonitor: ObservableObject {
    enum Access: Equatable { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown

    /// Fired on the main thread only on a granted → denied transition (a genuine mid-session
    /// revoke). The view uses this to flip the toggle off. It deliberately does NOT fire while
    /// access is merely "not yet granted", so enabling the toggle and waiting for the grant
    /// doesn't immediately turn itself back off.
    var onRevoked: (() -> Void)?

    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    func start() {
        refresh()
        // Periodic live probe so a revoke is detected even if the user never refocuses the app.
        // ~tens of ms per probe, off the main thread; 5s is responsive without being wasteful.
        let t = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        t.tolerance = 1.0
        timer = t
        // Re-check immediately when the app regains focus (e.g. returning from System Settings).
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let obs = activationObserver {
            NotificationCenter.default.removeObserver(obs)
            activationObserver = nil
        }
    }

    func refresh() {
        PermissionManager.shared.probePostEventAccessLive { [weak self] granted in
            guard let self = self else { return }
            let wasGranted = (self.access == .granted)
            self.access = granted ? .granted : .denied
            if wasGranted && !granted {
                self.onRevoked?()
            }
        }
    }

    deinit { stop() }
}
#endif

struct ClipboardHistoryTab: View {
    @AppStorage("maxHistorySize") private var maxHistorySize = 100
    @AppStorage("showClearAlert") private var showClearAlert = true
    @AppStorage("combineTextOnExport") private var combineTextOnExport = false
    @AppStorage("itemsInline") private var itemsInline = 10
    @AppStorage("itemsInFolder") private var itemsInFolder = 50
    @AppStorage("charsInMenu") private var charsInMenu = 30
    @AppStorage("markWithNumbers") private var markWithNumbers = true
    @AppStorage("showTooltip") private var showTooltip = true
    @AppStorage("tooltipMaxLength") private var tooltipMaxLength = 200
    @AppStorage("tooltipImageSize") private var tooltipImageSize = 240
    @AppStorage("showImagePreview") private var showImagePreview = true
    @AppStorage("imagePreviewWidth") private var imagePreviewWidth = 80
    @AppStorage("imagePreviewHeight") private var imagePreviewHeight = 50
#if ALLOW_AUTOPASTE
    @AppStorage("inputCmdV") private var inputCmdV = false
    @StateObject private var autoPasteMonitor = AutoPastePermissionMonitor()
#endif

    @State private var maxHistorySizeError: String? = nil
    @State private var itemsInlineError: String? = nil
    @State private var itemsInFolderError: String? = nil
    @State private var charsInMenuError: String? = nil
    @State private var tooltipMaxLengthError: String? = nil
    @State private var tooltipImageSizeError: String? = nil
    @State private var widthErrorMessage: String? = nil
    @State private var heightErrorMessage: String? = nil
    @FocusState private var maxHistorySizeFocused: Bool
    @FocusState private var itemsInlineFocused: Bool
    @FocusState private var itemsInFolderFocused: Bool
    @FocusState private var charsInMenuFocused: Bool
    @FocusState private var tooltipMaxLengthFocused: Bool
    @FocusState private var tooltipImageSizeFocused: Bool
    @FocusState private var widthFieldFocused: Bool
    @FocusState private var heightFieldFocused: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
#if ALLOW_AUTOPASTE
            // Auto-paste ships in EVERY build, including the sandboxed Mac App Store build:
            // `ALLOW_AUTOPASTE` is defined in all three app configs (Debug/Release/AppStore) in
            // project.pbxproj. The `#if` is a kill switch, not an App-Store exclusion. It posts a
            // single synthetic ⌘V via CGEvent.post, gated by the PostEvent TCC service
            // (kTCCServicePostEvent) — sandbox-compatible per Apple DTS and distinct from the
            // Accessibility (AX) API, even though macOS lists it under "Accessibility" in System
            // Settings. See APP_STORE_REVIEW_NOTES.md for the Guideline 2.4.5 justification.
            SectionHeader(title: "Auto Paste")

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Input \"⌘ + V\" after menu item selection", isOn: $inputCmdV)
                    .onChange(of: inputCmdV) { _, newValue in
                        guard newValue else { return }
                        // Request access. requestPostEventAccess() uses a LIVE probe to decide
                        // whether to show the system dialog (first ask) or deep-link to System
                        // Settings (after a prior decision the OS won't re-prompt). We never flip
                        // the toggle off here — the monitor does that only on a real revoke.
                        PermissionManager.shared.requestPostEventAccess()
                        // Nudge the banner so it reflects the new state quickly; the periodic
                        // probe and the app-activation re-check pick up the eventual grant.
                        autoPasteMonitor.refresh()
                    }

                Text("Pastes the selected item into the focused app. Needs Accessibility permission.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                autoPasteStatusBanner(autoPasteMonitor.access)
            }
            .onAppear {
                autoPasteMonitor.onRevoked = {
                    // A real mid-session revoke: turn the feature off so its state stays honest.
                    // @AppStorage observes UserDefaults, so the toggle updates to off.
                    UserDefaults.standard.set(false, forKey: "inputCmdV")
                }
                autoPasteMonitor.start()
            }
            .onDisappear {
                autoPasteMonitor.stop()
            }

            Divider()
                .padding(.vertical, 8)
#endif

            SectionHeader(title: "History")

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRow(label: "Max history size:") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Spacer(minLength: 8)
                            TextField("", value: $maxHistorySize, format: .number)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                                .focused($maxHistorySizeFocused)
                                .onChange(of: maxHistorySizeFocused) { _, focused in
                                    if !focused { validateMaxHistorySize(maxHistorySize) }
                                }
                            Text("items")
                                .foregroundColor(.secondary)
                        }
                        .frame(minWidth: 0, maxWidth: .infinity)
                    }
                    if let message = maxHistorySizeError {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                
                Toggle("Show confirmation before clearing history", isOn: $showClearAlert)
                
                Text("History is saved automatically and encrypted on disk.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()
                .padding(.vertical, 8)

            SectionHeader(title: "Auto-Clear")

            AutoClearHistorySection()

            Divider()
                .padding(.vertical, 8)
            
            SectionHeader(title: "Export")
            
            HStack(alignment: .center, spacing: 12) {
                Toggle("Combine text in one file", isOn: $combineTextOnExport)
                    .help("When enabled, text items are merged into a single .txt file; images are still exported as separate files.")
                Spacer(minLength: 8)
                Button("Export...") {
                    exportClipboardHistory()
                }
            }
            .frame(maxWidth: .infinity)
            
            Divider()
                .padding(.vertical, 8)
            
            SectionHeader(title: "Display Menu")
            
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRow(label: "Items shown inline:") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Spacer(minLength: 8)
                            TextField("", value: $itemsInline, format: .number)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                                .focused($itemsInlineFocused)
                                .onChange(of: itemsInlineFocused) { _, focused in
                                    if !focused { validateItemsInline(itemsInline) }
                                }
                            Text("items")
                                .foregroundColor(.secondary)
                        }
                        .frame(minWidth: 0, maxWidth: .infinity)
                    }
                    if let message = itemsInlineError {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.vertical, 4)
                
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRow(label: "Items per folder:") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Spacer(minLength: 8)
                            TextField("", value: $itemsInFolder, format: .number)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                                .focused($itemsInFolderFocused)
                                .onChange(of: itemsInFolderFocused) { _, focused in
                                    if !focused { validateItemsInFolder(itemsInFolder) }
                                }
                            Text("items")
                                .foregroundColor(.secondary)
                        }
                        .frame(minWidth: 0, maxWidth: .infinity)
                    }
                    if let message = itemsInFolderError {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.vertical, 4)
                
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRow(label: "Preview length:") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Spacer(minLength: 8)
                            TextField("", value: $charsInMenu, format: .number)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                                .focused($charsInMenuFocused)
                                .onChange(of: charsInMenuFocused) { _, focused in
                                    if !focused { validateCharsInMenu(charsInMenu) }
                                }
                            Text("chars")
                                .foregroundColor(.secondary)
                        }
                        .frame(minWidth: 0, maxWidth: .infinity)
                    }
                    if let message = charsInMenuError {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.vertical, 4)
                
                Toggle("Number menu items (1, 2, 3...)", isOn: $markWithNumbers)
                    .padding(.vertical, 4)
                
                Toggle("Show image previews", isOn: $showImagePreview)
                    .padding(.vertical, 4)
                if showImagePreview {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRow(label: "Preview size:") {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Spacer(minLength: 8)
                                TextField("", value: $imagePreviewWidth, format: .number)
                                    .frame(width: 50)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($widthFieldFocused)
                                    .onChange(of: widthFieldFocused) { _, newValue in
                                        if !newValue { validateWidth(imagePreviewWidth) }
                                    }
                                Text("×")
                                TextField("", value: $imagePreviewHeight, format: .number)
                                    .frame(width: 50)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($heightFieldFocused)
                                    .onChange(of: heightFieldFocused) { _, newValue in
                                        if !newValue { validateHeight(imagePreviewHeight) }
                                    }
                                Text("px")
                                    .foregroundColor(.secondary)
                            }
                            .frame(minWidth: 0, maxWidth: .infinity)
                        }
                        if let message = widthErrorMessage ?? heightErrorMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.orange)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.vertical, 4)
                }

                Toggle("Show tooltip on hover", isOn: $showTooltip)
                    .padding(.vertical, 4)
                if showTooltip {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRow(label: "Tooltip length:") {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Spacer(minLength: 8)
                                TextField("", value: $tooltipMaxLength, format: .number)
                                    .frame(width: 60)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($tooltipMaxLengthFocused)
                                    .onChange(of: tooltipMaxLengthFocused) { _, focused in
                                        if !focused { validateTooltipMaxLength(tooltipMaxLength) }
                                    }
                                Text("chars")
                                    .foregroundColor(.secondary)
                            }
                            .frame(minWidth: 0, maxWidth: .infinity)
                        }
                        if let message = tooltipMaxLengthError {
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.orange)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.vertical, 4)

                    // Image rows have no hover text, so they preview themselves at this size.
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRow(label: "Tooltip size:") {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Spacer(minLength: 8)
                                TextField("", value: $tooltipImageSize, format: .number)
                                    .frame(width: 60)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($tooltipImageSizeFocused)
                                    .onChange(of: tooltipImageSizeFocused) { _, focused in
                                        if !focused { validateTooltipImageSize(tooltipImageSize) }
                                    }
                                Text("px")
                                    .foregroundColor(.secondary)
                            }
                            .frame(minWidth: 0, maxWidth: .infinity)
                        }
                        if let message = tooltipImageSizeError {
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.orange)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.vertical, 4)
                }

            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            clampAllNumericValues()
        }
    }
    
    private func clampAllNumericValues() {
        let (minH, maxH) = (10, 500)
        if maxHistorySize < minH || maxHistorySize > maxH {
            maxHistorySize = min(maxH, max(minH, maxHistorySize))
        }
        let (minI, maxI) = (1, 100)
        if itemsInline < minI || itemsInline > maxI {
            itemsInline = min(maxI, max(minI, itemsInline))
        }
        let (minF, maxF) = (1, 500)
        if itemsInFolder < minF || itemsInFolder > maxF {
            itemsInFolder = min(maxF, max(minF, itemsInFolder))
        }
        let (minC, maxC) = (1, 500)
        if charsInMenu < minC || charsInMenu > maxC {
            charsInMenu = min(maxC, max(minC, charsInMenu))
        }
        let (minT, maxT) = (1, 2000)
        if tooltipMaxLength < minT || tooltipMaxLength > maxT {
            tooltipMaxLength = min(maxT, max(minT, tooltipMaxLength))
        }
        let (minTS, maxTS) = (40, 600)
        if tooltipImageSize < minTS || tooltipImageSize > maxTS {
            tooltipImageSize = min(maxTS, max(minTS, tooltipImageSize))
        }
        if imagePreviewWidth < 1 || imagePreviewWidth > 360 {
            imagePreviewWidth = min(360, max(1, imagePreviewWidth))
        }
        if imagePreviewHeight < 1 || imagePreviewHeight > 360 {
            imagePreviewHeight = min(360, max(1, imagePreviewHeight))
        }
    }
    
    private func setErrorTemporary(_ binding: Binding<String?>, _ value: String?) {
        binding.wrappedValue = value
        if value != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                binding.wrappedValue = nil
            }
        }
    }
    
#if ALLOW_AUTOPASTE
    /// Green / red (no button) status banner for the auto-paste Accessibility permission. Red
    /// until permission is granted, green once it is; on a mid-session revoke the toggle auto-offs
    /// and this returns to red. State comes from the live fresh-process probe, not the stale
    /// in-process preflight cache.
    private func autoPasteStatusBanner(_ access: AutoPastePermissionMonitor.Access) -> some View {
        let color: Color
        let symbol: String
        let message: String
        switch access {
        case .granted:
            color = .green
            symbol = "checkmark.circle.fill"
            message = "Accessibility permission granted — auto-paste is active."
        case .denied:
            color = .red
            symbol = "exclamationmark.triangle.fill"
            message = "Accessibility permission needed. Enable Topkit under System Settings ▸ Privacy & Security ▸ Accessibility."
        case .unknown:
            color = .secondary
            symbol = "clock.fill"
            message = "Checking accessibility permission…"
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundColor(color)
            Text(message)
                .font(.caption)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.45), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: access)
    }
#endif

    private func validateMaxHistorySize(_ value: Int) {
        let (minV, maxV) = (10, 500)
        if value > maxV {
            maxHistorySize = maxV
            setErrorTemporary($maxHistorySizeError, "Value must be between \(minV) and \(maxV).")
        } else if value < minV {
            maxHistorySize = minV
            setErrorTemporary($maxHistorySizeError, "Value must be between \(minV) and \(maxV).")
        } else {
            maxHistorySizeError = nil
        }
    }
    
    private func validateItemsInline(_ value: Int) {
        let (minV, maxV) = (1, 100)
        if value > maxV {
            itemsInline = maxV
            setErrorTemporary($itemsInlineError, "Value must be between \(minV) and \(maxV).")
        } else if value < minV {
            itemsInline = minV
            setErrorTemporary($itemsInlineError, "Value must be between \(minV) and \(maxV).")
        } else {
            itemsInlineError = nil
        }
    }
    
    private func validateItemsInFolder(_ value: Int) {
        let (minV, maxV) = (1, 500)
        if value > maxV {
            itemsInFolder = maxV
            setErrorTemporary($itemsInFolderError, "Value must be between \(minV) and \(maxV).")
        } else if value < minV {
            itemsInFolder = minV
            setErrorTemporary($itemsInFolderError, "Value must be between \(minV) and \(maxV).")
        } else {
            itemsInFolderError = nil
        }
    }
    
    private func validateCharsInMenu(_ value: Int) {
        let (minV, maxV) = (1, 500)
        if value > maxV {
            charsInMenu = maxV
            setErrorTemporary($charsInMenuError, "Value must be between \(minV) and \(maxV).")
        } else if value < minV {
            charsInMenu = minV
            setErrorTemporary($charsInMenuError, "Value must be between \(minV) and \(maxV).")
        } else {
            charsInMenuError = nil
        }
    }
    
    private func validateTooltipMaxLength(_ value: Int) {
        let (minV, maxV) = (1, 2000)
        if value > maxV {
            tooltipMaxLength = maxV
            setErrorTemporary($tooltipMaxLengthError, "Value must be between \(minV) and \(maxV).")
        } else if value < minV {
            tooltipMaxLength = minV
            setErrorTemporary($tooltipMaxLengthError, "Value must be between \(minV) and \(maxV).")
        } else {
            tooltipMaxLengthError = nil
        }
    }

    private func validateTooltipImageSize(_ value: Int) {
        let (minV, maxV) = (40, 600)
        if value > maxV {
            tooltipImageSize = maxV
            setErrorTemporary($tooltipImageSizeError, "Value must be between \(minV) and \(maxV).")
        } else if value < minV {
            tooltipImageSize = minV
            setErrorTemporary($tooltipImageSizeError, "Value must be between \(minV) and \(maxV).")
        } else {
            tooltipImageSizeError = nil
        }
    }

    private func validateWidth(_ value: Int) {
        let (minV, maxV) = (1, 360)
        if value > maxV {
            imagePreviewWidth = maxV
            setErrorTemporary($widthErrorMessage, "Value must be between \(minV) and \(maxV) px.")
        } else if value < minV {
            imagePreviewWidth = minV
            setErrorTemporary($widthErrorMessage, "Value must be between \(minV) and \(maxV) px.")
        } else {
            widthErrorMessage = nil
        }
    }
    
    private func validateHeight(_ value: Int) {
        let (minV, maxV) = (1, 360)
        if value > maxV {
            imagePreviewHeight = maxV
            setErrorTemporary($heightErrorMessage, "Value must be between \(minV) and \(maxV) px.")
        } else if value < minV {
            imagePreviewHeight = minV
            setErrorTemporary($heightErrorMessage, "Value must be between \(minV) and \(maxV) px.")
        } else {
            heightErrorMessage = nil
        }
    }
    
    private func exportClipboardHistory() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            
            let history = ClipboardManager.shared.clipboardHistory
            guard !history.isEmpty else {
                let alert = NSAlert()
                alert.messageText = "Nothing to Export"
                alert.informativeText = "Your clipboard history is empty."
                alert.alertStyle = .informational
                alert.runModal()
                return
            }
            
            let combineText = UserDefaults.standard.bool(forKey: "combineTextOnExport")
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.title = "Choose Export Folder"
            panel.prompt = "Export Here"
            
            panel.begin { response in
                guard response == .OK, let folderURL = panel.url else { return }

                // Writing can touch many large image files; keep it off the main thread so the
                // panel/UI never blocks while a big history is exported.
                DispatchQueue.global(qos: .userInitiated).async {
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                    let lf = "\n"
                    var failedWrites = 0

                    func write(_ data: Data, to fileURL: URL) {
                        do {
                            try data.write(to: fileURL)
                        } catch {
                            failedWrites += 1
                        }
                    }

                    if combineText {
                        let textItems = history.filter { $0.type == .text }
                        if !textItems.isEmpty {
                            let content = textItems.map { $0.content }.joined(separator: lf + lf)
                            if let data = content.data(using: .utf8) {
                                write(data, to: folderURL.appendingPathComponent("combined_text.txt"))
                            }
                        }
                        for (index, item) in history.enumerated() {
                            let timestamp = dateFormatter.string(from: item.timestamp)
                            switch item.type {
                            case .text:
                                break
                            case .image:
                                // Stored bytes are already PNG on disk — copy them straight through
                                // instead of decoding to NSImage and re-encoding.
                                if let imageData = ClipboardManager.shared.fullImageData(for: item) {
                                    write(imageData, to: folderURL.appendingPathComponent("\(index + 1)_\(timestamp).png"))
                                } else {
                                    failedWrites += 1
                                }
                            case .file:
                                if let data = item.content.data(using: .utf8) {
                                    write(data, to: folderURL.appendingPathComponent("\(index + 1)_\(timestamp)_files.txt"))
                                }
                            }
                        }
                    } else {
                        for (index, item) in history.enumerated() {
                            let timestamp = dateFormatter.string(from: item.timestamp)
                            let filename: String
                            let content: Data?
                            switch item.type {
                            case .text:
                                filename = "\(index + 1)_\(timestamp).txt"
                                content = item.content.data(using: .utf8)
                            case .image:
                                filename = "\(index + 1)_\(timestamp).png"
                                content = ClipboardManager.shared.fullImageData(for: item)
                            case .file:
                                filename = "\(index + 1)_\(timestamp)_files.txt"
                                content = item.content.data(using: .utf8)
                            }
                            if let data = content {
                                write(data, to: folderURL.appendingPathComponent(filename))
                            } else if item.type == .image {
                                failedWrites += 1
                            }
                        }
                    }

                    DispatchQueue.main.async {
                        if failedWrites > 0 {
                            let alert = NSAlert()
                            alert.messageText = "Export Incomplete"
                            alert.informativeText = "\(failedWrites) item\(failedWrites == 1 ? "" : "s") could not be exported. Check the folder's permissions and free disk space."
                            alert.alertStyle = .warning
                            alert.runModal()
                        }
                        NSWorkspace.shared.open(folderURL)
                    }
                }
            }
        }
    }
}

// MARK: - Shortcuts Tab

struct ShortcutsTab: View {
    @AppStorage("shortcutPickColor") private var shortcutPickColor = ""
    @AppStorage("shortcutMagnifyingGlass") private var shortcutMagnifyingGlass = ""
    @AppStorage("shortcutDraw") private var shortcutDraw = ""
    @AppStorage("shortcutAnnotateRectangle") private var shortcutAnnotateRectangle = ""
    @AppStorage("shortcutAnnotateCircle") private var shortcutAnnotateCircle = ""
    @AppStorage("shortcutAnnotateArrow") private var shortcutAnnotateArrow = ""
    @AppStorage("shortcutAnnotateText") private var shortcutAnnotateText = ""
    @AppStorage("shortcutAnnotateRedact") private var shortcutAnnotateRedact = ""
    @AppStorage("shortcutAnnotateSticker") private var shortcutAnnotateSticker = ""
    @AppStorage("shortcutAnnotateBadge") private var shortcutAnnotateBadge = ""
    @AppStorage("shortcutHalo") private var shortcutHalo = ""
    @AppStorage("shortcutMeasure") private var shortcutMeasure = ""
    @AppStorage("shortcutAddGuide") private var shortcutAddGuide = ""
    @AppStorage("shortcutAddVerticalGuide") private var shortcutAddVerticalGuide = ""
    @AppStorage("shortcutAddRectangle") private var shortcutAddRectangle = ""
    @AppStorage("shortcutScreenshot") private var shortcutScreenshot = ""
    @AppStorage("shortcutRecordScreen") private var shortcutRecordScreen = ""
    @AppStorage("shortcutClearClipboard") private var shortcutClearClipboard = ""
    @AppStorage("shortcutOpenPreferences") private var shortcutOpenPreferences = ""
    @AppStorage("shortcutClipboardMenu") private var shortcutClipboardMenu = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Shortcuts")

            Text("Click on a field and press your desired key combination.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 8) {
                // Order matches the Topkit menu: Screenshot, Record, Pick Color,
                // Magnify, Halo, then Annotate (last). Annotate tools are a submenu,
                // so they get a grouped block here rather than sitting inline.
                ShortcutRow(label: "Screenshot:", shortcut: $shortcutScreenshot)
                ShortcutRow(label: "Record Screen:", shortcut: $shortcutRecordScreen)
                ShortcutRow(label: "Pick Color:", shortcut: $shortcutPickColor)
                ShortcutRow(label: "Magnify:", shortcut: $shortcutMagnifyingGlass)
                ShortcutRow(label: "Halo:", shortcut: $shortcutHalo)

                Text("Annotate")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
                ShortcutRow(label: "Freehand:", shortcut: $shortcutDraw)
                ShortcutRow(label: "Rectangle:", shortcut: $shortcutAnnotateRectangle)
                ShortcutRow(label: "Circle:", shortcut: $shortcutAnnotateCircle)
                ShortcutRow(label: "Arrow:", shortcut: $shortcutAnnotateArrow)
                ShortcutRow(label: "Text:", shortcut: $shortcutAnnotateText)
                ShortcutRow(label: "Redact:", shortcut: $shortcutAnnotateRedact)
                ShortcutRow(label: "Sticker:", shortcut: $shortcutAnnotateSticker)
                ShortcutRow(label: "Numbered Badge:", shortcut: $shortcutAnnotateBadge)
                ShortcutRow(label: "Measure:", shortcut: $shortcutMeasure)
                ShortcutRow(label: "Vertical Guide:", shortcut: $shortcutAddVerticalGuide)
                ShortcutRow(label: "Horizontal Guide:", shortcut: $shortcutAddGuide)
                ShortcutRow(label: "Grid:", shortcut: $shortcutAddRectangle)

                ShortcutRow(label: "Clear Clipboard:", shortcut: $shortcutClearClipboard)
                ShortcutRow(label: "Open Preferences:", shortcut: $shortcutOpenPreferences)
                ShortcutRow(label: "Clipboard Menu:", shortcut: $shortcutClipboardMenu)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - About Tab

/// The version line About shows: `1.0 (251)`.
///
/// Two different numbers. `CFBundleShortVersionString` is the public one, the App
/// Store listing's `1.0`. `CFBundleVersion` says which build of that version this
/// copy is, and the target's "Stamp Build Number" phase writes the git commit count
/// there, so the line names the exact commit a report came from.
enum AppVersionLabel {
    static func text(short: String?, build: String?) -> String {
        let version = short.flatMap { $0.isEmpty ? nil : $0 } ?? "1.0"
        guard let build = build.flatMap({ $0.isEmpty ? nil : $0 }) else { return version }
        return "\(version) (\(build))"
    }

    static var current: String {
        text(
            short: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        )
    }
}

struct AboutTab: View {
    private static let iconSize: CGFloat = 64

    private var versionString: String { AppVersionLabel.current }

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
                .frame(maxHeight: 100)

            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Self.iconSize, height: Self.iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Text("Topkit")
                .font(.title2)
                .fontWeight(.semibold)

            // Selectable so the build number can be pasted into a bug report.
            Text("Version \(versionString)")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .textSelection(.enabled)

            Link("Website", destination: URL(string: "https://topkitapp.com/")!)
                .font(.caption)

            Spacer(minLength: 0)

            Text("© 2026")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, minHeight: 500)
    }
}

// MARK: - Helper Views

struct SectionHeader: View {
    let title: LocalizedStringKey
    
    var body: some View {
        Text(title)
            .font(.headline)
            .padding(.bottom, 4)
    }
}

struct SettingsRow<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let content: Content
    
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: 180, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            content
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ShortcutRow: View {
    let label: LocalizedStringKey
    @Binding var shortcut: String
    @State private var isRecording = false
    
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: 180, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Spacer(minLength: 8)
                ShortcutRecorderView(shortcut: $shortcut, isRecording: $isRecording)
                    .frame(width: 120, height: 24)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isRecording ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
                    )
                Button("Clear") {
                    shortcut = ""
                    NotificationCenter.default.post(name: NSNotification.Name("ReloadShortcuts"), object: nil)
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .font(.caption)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: String
    @Binding var isRecording: Bool
    
    func makeNSView(context: Context) -> ShortcutTextField {
        let field = ShortcutTextField()
        field.shortcutBinding = $shortcut
        field.isRecordingBinding = $isRecording
        field.stringValue = shortcut.isEmpty ? "Click to set" : shortcut
        field.alignment = .center
        field.isBordered = false
        field.backgroundColor = .clear
        field.font = .systemFont(ofSize: 11)
        field.delegate = context.coordinator
        return field
    }
    
    func updateNSView(_ nsView: ShortcutTextField, context: Context) {
        if isRecording {
            nsView.stringValue = "Press keys..."
            nsView.textColor = .systemBlue
        } else {
            nsView.stringValue = shortcut.isEmpty ? "Click to set" : shortcut
            nsView.textColor = shortcut.isEmpty ? .placeholderTextColor : .labelColor
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ShortcutRecorderView
        
        init(_ parent: ShortcutRecorderView) {
            self.parent = parent
        }
    }
}

class ShortcutTextField: NSTextField {
    var shortcutBinding: Binding<String>?
    var isRecordingBinding: Binding<Bool>?
    
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    private func setup() {
        isEditable = false
        isSelectable = false
        focusRingType = .none
    }
    
    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        guard becameFirstResponder else {
            return false
        }

        isRecordingBinding?.wrappedValue = true
        stringValue = "Press keys..."
        textColor = .systemBlue
        return true
    }
    
    override func resignFirstResponder() -> Bool {
        isRecordingBinding?.wrappedValue = false
        if let binding = shortcutBinding {
            stringValue = binding.wrappedValue.isEmpty ? "Click to set" : binding.wrappedValue
            textColor = binding.wrappedValue.isEmpty ? .placeholderTextColor : .labelColor
        }
        return super.resignFirstResponder()
    }
    
    override func keyDown(with event: NSEvent) {
        guard let binding = shortcutBinding else {
            super.keyDown(with: event)
            return
        }
        
        // Escape cancels
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return
        }
        
        var parts: [String] = []
        
        if event.modifierFlags.contains(.control) { parts.append("⌃") }
        if event.modifierFlags.contains(.option) { parts.append("⌥") }
        if event.modifierFlags.contains(.shift) { parts.append("⇧") }
        if event.modifierFlags.contains(.command) { parts.append("⌘") }
        
        var keyChar: String? = nil
        
        switch event.keyCode {
        case 36: keyChar = "↩"
        case 48: keyChar = "⇥"
        case 49: keyChar = "␣"
        case 51: keyChar = "⌫"
        case 53: keyChar = "⎋"
        default:
            if let chars = event.charactersIgnoringModifiers?.uppercased(), !chars.isEmpty {
                let key = chars.first!
                if key.isLetter || key.isNumber || "!@#$%^&*()_+-=[]{}|;':\",./<>?".contains(key) {
                    keyChar = String(key)
                }
            }
        }
        
        if let key = keyChar {
            parts.append(key)
        }
        
        if parts.count >= 2 {
            binding.wrappedValue = parts.joined()
            window?.makeFirstResponder(nil)
            NotificationCenter.default.post(name: NSNotification.Name("ReloadShortcuts"), object: nil)
        } else if !parts.isEmpty {
            stringValue = parts.joined() + "..."
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
    }
    
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecordingBinding?.wrappedValue == true {
            keyDown(with: event)
            return true
        }
        return false
    }
}

