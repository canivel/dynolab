import DynoKit
import SwiftUI
import WebKit

/// The Browser tab: the page a served model is using, what it did step by step, its mode, and the user's controls
/// (approve, pause, take over by using the page).
struct BrowserView: View {
    @Bindable var browser: BrowserController

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let approval = browser.approval { approvalBanner(approval) }
            if let error = browser.bridgeError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            HStack(spacing: 0) {
                ZStack {
                    BrowserWebView(webView: browser.webView)
                    if browser.address.isEmpty { emptyState }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                activity.frame(width: 280)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!browser.canGoBack).help("Back")
            Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!browser.canGoForward).help("Forward")
            Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
            TextField("Address", text: $browser.address)
                .textFieldStyle(.roundedBorder)
                .onSubmit { browser.userOpen(browser.address) }
            Picker("Model can", selection: $browser.mode) {
                ForEach(BrowserMode.allCases) { Text($0.title).tag($0) }
            }.frame(width: 300)
                .help(browser.mode.detail)
            Button {
                browser.paused.toggle()
            } label: {
                Label(browser.paused ? "Let the model continue" : "Pause the model",
                      systemImage: browser.paused ? "play.fill" : "pause.fill")
            }.help(browser.paused ? "The model's browser steps are refused until you let it continue."
                   : "Stop the model's browser steps, for example to take over and use the page yourself.")
        }.padding(10)
    }

    private func approvalBanner(_ approval: BrowserController.Approval) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill").foregroundStyle(DynoBrand.accent).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Allow this step?").font(.headline)
                Text(approval.message).font(.callout).textSelection(.enabled)
                Text("If you don't answer within 5 minutes, it isn't allowed.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Don't allow") { browser.answer(false) }.keyboardShortcut(.cancelAction)
            Button("Allow") { browser.answer(true) }.keyboardShortcut(.defaultAction).buttonStyle(.dynoPrimary)
        }
        .padding(12)
        .background(DynoBrand.surface)
        .overlay(alignment: .leading) { DynoBrand.lime.frame(width: 4) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("The model's browser").font(.title3.weight(.semibold))
            Text("Models started with **Web access** in Models can open pages here, read them and, if you allow it, click and type. You see every step and can pause it or take over.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            Text(browser.mode.detail).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            Text("Its cookies and logins are its own, separate from Safari and your other browsers. It opens public pages only, never this Mac or your local network.")
                .font(.caption).multilineTextAlignment(.center).foregroundStyle(.tertiary).frame(maxWidth: 460)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DynoBrand.background)
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("What the model did").font(.headline)
                Spacer()
                if browser.acting { ProgressView().controlSize(.small) }
                Button("Clear") { browser.clearSteps() }.buttonStyle(.borderless).disabled(browser.steps.isEmpty)
            }.padding(10)
            Divider()
            if browser.steps.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary).padding(10)
                Spacer()
            } else {
                List(browser.steps.reversed()) { step in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(step.text).font(.callout.weight(.medium))
                            Spacer()
                            Text(step.time, style: .time).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let outcome = step.outcome {
                            Text(outcome).font(.caption).foregroundStyle(step.failed ? Color.orange : Color.secondary).lineLimit(3)
                        }
                    }.padding(.vertical, 2)
                }.listStyle(.plain)
            }
        }
    }
}

private struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
