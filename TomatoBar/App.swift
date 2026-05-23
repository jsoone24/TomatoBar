import CoreServices
import SwiftUI
import LaunchAtLogin

extension NSImage.Name {
    static let idle = Self("BarIconIdle")
    static let work = Self("BarIconWork")
    static let shortRest = Self("BarIconShortRest")
    static let longRest = Self("BarIconLongRest")
}

private let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular)
private let statusTitleCharacterWidth: CGFloat = 8
private let statusTitleBaseWidth: CGFloat = 28

@main
struct TBApp: App {
    @NSApplicationDelegateAdaptor(TBStatusItem.self) var appDelegate

    init() {
        TBStatusItem.shared = appDelegate
        LaunchAtLogin.migrateIfNeeded()
        logger.append(event: TBLogEventAppStart())
    }

    var body: some Scene {
        Settings {}
    }
}

class TBStatusItem: NSObject, NSApplicationDelegate {
    private var popover = NSPopover()
    private var statusBarItem: NSStatusItem?
    static var shared: TBStatusItem!

    func applicationDidFinishLaunching(_: Notification) {
        TBWidgetExtensionRegistrar.register()

        statusBarItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        statusBarItem?.button?.imagePosition = .imageLeft
        setIcon(name: .idle)
        statusBarItem?.button?.action = #selector(TBStatusItem.togglePopover(_:))

        let view = TBPopoverView()

        popover.behavior = .transient
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = NSHostingView(rootView: view)
        if let contentViewController = popover.contentViewController {
            popover.contentSize.height = contentViewController.view.intrinsicContentSize.height
            popover.contentSize.width = 300
        }
    }

    func setTitle(title: String?) {
        if let title = title {
            let visibleCharacterCount = max(title.count, 5)
            statusBarItem?.length = statusTitleBaseWidth + CGFloat(visibleCharacterCount) * statusTitleCharacterWidth
        } else {
            statusBarItem?.length = NSStatusItem.squareLength
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 0.9
        paragraphStyle.alignment = NSTextAlignment.center

        let attributedTitle = NSAttributedString(
            string: title != nil ? " \(title!)" : "",
            attributes: [
                NSAttributedString.Key.font: digitFont,
                NSAttributedString.Key.paragraphStyle: paragraphStyle
            ]
        )
        statusBarItem?.button?.attributedTitle = attributedTitle
        realignPopoverIfNeeded()
    }

    func setIcon(name: NSImage.Name) {
        statusBarItem?.button?.image = NSImage(named: name)
    }

    func setPopoverContentSize(width: CGFloat, height: CGFloat) {
        let size = NSSize(width: width, height: height)
        guard popover.contentSize != size else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                self.popover.contentSize = size
            }
            self.realignPopoverIfNeeded()
        }
    }

    func showPopover(_: AnyObject?) {
        if let button = statusBarItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover(_ sender: AnyObject?) {
        popover.performClose(sender)
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover(sender)
        } else {
            showPopover(sender)
        }
    }

    private func realignPopoverIfNeeded() {
        guard popover.isShown else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.popover.isShown,
                  let button = self.statusBarItem?.button else {
                return
            }

            self.popover.positioningRect = button.bounds
        }
    }
}

private enum TBWidgetExtensionRegistrar {
    private static let extensionRelativePath = "Contents/PlugIns/TomatoBarWidgetExtension.appex"

    static func register() {
        registerContainingBundle()
        registerWidgetExtension()
    }

    private static func registerContainingBundle() {
        let status = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        guard status != noErr else {
            return
        }

        print("widget registration warning: Launch Services returned \(status)")
    }

    private static func registerWidgetExtension() {
        let extensionURL = Bundle.main.bundleURL.appendingPathComponent(extensionRelativePath)
        guard FileManager.default.fileExists(atPath: extensionURL.path) else {
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            process.arguments = ["-a", extensionURL.path]

            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus != 0 else {
                    return
                }
                print("widget registration warning: pluginkit exited with \(process.terminationStatus)")
            } catch {
                print("widget registration warning: cannot run pluginkit: \(error)")
            }
        }
    }
}
