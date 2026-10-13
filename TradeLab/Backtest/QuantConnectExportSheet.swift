import SwiftUI
import UIKit

struct QuantConnectScript: Identifiable {
    let id = UUID()
    let text: String
    let fileName: String
    let isOptions: Bool

    /// Skript uložený do dočasné složky, ať jde sdílet jako soubor `.py`.
    var fileURL: URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

struct QuantConnectExportSheet: View {
    let script: QuantConnectScript
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var fileURL: URL? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Otevři **quantconnect.com** → Algorithm Lab → **Create New Algorithm** (Python).")
                        Text("2. Celý obsah `main.py` nahraď tímto skriptem.")
                        Text("3. Klikni na **Backtest** – výsledky (equity, statistiky, obchody) uvidíš přímo v QuantConnectu.")
                        if script.isOptions {
                            Text("Opce běží na minutových kotacích QuantConnectu (od 2012) – výsledek se bude lišit od simulace v aplikaci, protože jde o skutečné ceny a spready.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Akcie obchoduje na denních svíčkách; signál ze zavírací ceny, plnění na otevření další svíčky.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                } header: {
                    Text("Postup")
                }

                Section {
                    Button {
                        UIPasteboard.general.string = script.text
                        copied = true
                    } label: {
                        Label(copied ? "Zkopírováno" : "Kopírovat skript",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    if let fileURL {
                        ShareLink(item: fileURL) {
                            Label("Sdílet jako \(script.fileName)", systemImage: "square.and.arrow.up")
                        }
                    }
                    if let url = URL(string: "https://www.quantconnect.com/terminal") {
                        Link(destination: url) {
                            Label("Otevřít QuantConnect", systemImage: "safari")
                        }
                    }
                }

                Section {
                    ScrollView(.horizontal) {
                        Text(script.text)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.vertical, 4)
                    }
                } header: {
                    Text("main.py · \(script.text.split(separator: "\n", omittingEmptySubsequences: false).count) řádků")
                }
            }
            .navigationTitle("QuantConnect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hotovo") { dismiss() }
                }
            }
            .task { fileURL = script.fileURL }
        }
    }
}
