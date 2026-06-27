import SwiftUI

struct SettingsView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(GamesViewModel.self) var viewModel

    var body: some View {
        @Bindable var vm = viewModel

        NavigationStack {
            Form {
                Section("Server") {
                    Picker("Region", selection: $vm.streamSettings.zoneRegion) {
                        ForEach(ZoneRegion.allCases, id: \.self) { region in
                            Text(region.label).tag(region)
                        }
                    }
                    .onChange(of: vm.streamSettings.zoneRegion) {
                        viewModel.startBackgroundZoneProbing()
                    }
                    if viewModel.probeZoneCount > 0 {
                        if let best = viewModel.probeBestZone, let ping = viewModel.probeBestPing {
                            LabeledContent("Best Server", value: "\(best) (\(ping) ms)")
                        }
                        LabeledContent("Probing", value: "\(viewModel.probeActiveCount) of \(viewModel.probeZoneCount) zones")
                    }
                }

                Section("Stream Quality") {
                    Picker("Resolution", selection: $vm.streamSettings.resolution) {
                        let common = commonResolutions.filter { viewModel.availableResolutions.contains($0.res) }
                        let other  = viewModel.availableResolutions.filter { res in !commonResolutions.map(\.res).contains(res) }
                        if !common.isEmpty {
                            Section("TV Standards") {
                                ForEach(common, id: \.res) { item in
                                    Label("\(item.res)  —  \(item.badge)", systemImage: item.symbol)
                                        .tag(item.res)
                                }
                            }
                        }
                        if !other.isEmpty {
                            Section("Other") {
                                ForEach(other, id: \.self) { res in
                                    Text(res).tag(res)
                                }
                            }
                        }
                    }

                    Picker("Frame Rate", selection: $vm.streamSettings.fps) {
                        ForEach(viewModel.availableFps, id: \.self) { fps in
                            Text("\(fps) fps").tag(fps)
                        }
                    }

                    Picker("Codec", selection: $vm.streamSettings.codec) {
                        ForEach(VideoCodec.allCases, id: \.self) { codec in
                            Text(codec.rawValue).tag(codec)
                        }
                    }


                    Picker("Keyboard Layout", selection: $vm.streamSettings.keyboardLayout) {
                        Text("English (US)").tag("en-US")
                        Text("English (UK)").tag("en-GB")
                        Text("French").tag("fr-FR")
                        Text("German").tag("de-DE")
                        Text("Spanish").tag("es-ES")
                        Text("Italian").tag("it-IT")
                        Text("Portuguese (Brazil)").tag("pt-BR")
                        Text("Hindi (India)").tag("hi-IN")
                        Text("Japanese").tag("ja-JP")
                        Text("Korean").tag("ko-KR")
                    }

                    Picker("Game Language", selection: $vm.streamSettings.gameLanguage) {
                        Text("English (US)").tag("en_US")
                        Text("English (UK)").tag("en_GB")
                        Text("French").tag("fr_FR")
                        Text("German").tag("de_DE")
                        Text("Spanish").tag("es_ES")
                        Text("Italian").tag("it_IT")
                        Text("Portuguese").tag("pt_BR")
                        Text("Hindi").tag("hi_IN")
                        Text("Japanese").tag("ja_JP")
                        Text("Korean").tag("ko_KR")
                    }

                    LabeledContent("Max Bitrate") {
                        HStack(spacing: 16) {
                            Button {
                                vm.streamSettings.maxBitrateKbps = max(15_000, vm.streamSettings.maxBitrateKbps - 5_000)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            Text("\(vm.streamSettings.maxBitrateKbps / 1000) Mbps")
                                .monospacedDigit()
                                .frame(minWidth: 72)
                                .padding(.horizontal, 24)
                            Button {
                                vm.streamSettings.maxBitrateKbps = min(100_000, vm.streamSettings.maxBitrateKbps + 5_000)
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Toggle(isOn: $vm.streamSettings.enableL4S) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Low Latency Mode (L4S)")
                            Text("Reduces buffering on networks with L4S support (requires a compatible router and ISP).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }

                Section("Microphone") {
                    Toggle(isOn: $vm.streamSettings.micEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Use Microphone")
                            Text("Enables voice chat via a connected Bluetooth headset or AirPods. Requires microphone permission.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }

                Section("Controller") {
                    LabeledContent {
                        HStack(spacing: 16) {
                            Button {
                                vm.streamSettings.controllerDeadzone = max(0.05, vm.streamSettings.controllerDeadzone - 0.01)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            Text("\(Int(vm.streamSettings.controllerDeadzone * 100))%")
                                .monospacedDigit()
                                .frame(minWidth: 44)
                                .padding(.horizontal, 24)
                            Button {
                                vm.streamSettings.controllerDeadzone = min(0.30, vm.streamSettings.controllerDeadzone + 0.01)
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Deadzone")
                            Text("Increase if your controller drifts at rest. Default: 15%.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    Picker(selection: $vm.streamSettings.overlayTriggerButton) {
                        ForEach(OverlayTriggerButton.allCases, id: \.self) { btn in
                            Text(btn.rawValue).tag(btn)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Overlay Button")
                            Text("Long-press this button during play to open the app overlay. Switch if it conflicts with an in-game action.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    Toggle(isOn: $vm.streamSettings.enableSteamOverlayGesture) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Steam Overlay Gesture")
                            Text("Long-press the OTHER button (the one not set as Overlay Button) to send Shift+Tab and open the Steam overlay. e.g. with Overlay on Start, long-press View/Back.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    Picker(selection: $vm.streamSettings.defaultRemoteInputMode) {
                        Text("Mouse").tag(RemoteInputMode.mouse)
                        Text("Gamepad").tag(RemoteInputMode.gamepad)
                        Text("DualSense").tag(RemoteInputMode.dualsense)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Default Input Mode")
                            Text("Siri Remote mode at stream start. Can be changed mid-session from the overlay menu.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    LabeledContent("Protocol", value: "XInput over GFN v2/v3")
                }

                Section("Account") {
                    if let user = authManager.session?.user {
                        LabeledContent("Name", value: user.displayName)
                        if let email = user.email {
                            LabeledContent("Email", value: email)
                        }
                        if let sub = viewModel.subscription {
                            LabeledContent("Membership", value: sub.membershipTier)
                            if !sub.isUnlimited, let remaining = sub.remainingMinutes {
                                let hours = remaining / 60
                                let mins  = remaining % 60
                                LabeledContent("Time Remaining", value: hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m")
                            }
                        } else {
                            LabeledContent("Membership", value: user.membershipTier)
                        }
                    }

                    Button(role: .destructive) {
                        authManager.logout()
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("")
        }
    }

    private struct ResolutionEntry { let res: String; let badge: String; let symbol: String }
    private let commonResolutions: [ResolutionEntry] = [
        ResolutionEntry(res: "1280x720",  badge: "HD",      symbol: "tv"),
        ResolutionEntry(res: "1920x1080", badge: "Full HD", symbol: "tv"),
        ResolutionEntry(res: "2560x1440", badge: "2K",      symbol: "tv"),
        ResolutionEntry(res: "3840x2160", badge: "4K",      symbol: "4k.tv"),
    ]

}


