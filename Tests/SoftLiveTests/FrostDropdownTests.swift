import AppKit
import SwiftUI
import Testing
@testable import SoftLive

struct FrostDropdownTests {
    @Test func menuOriginPlacesMenuStrictlyBelowTriggerAndAlignsEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 28)

        let leadingWider = FrostDropdownLayout.menuOrigin(
            bounds: bounds,
            menuWidth: 180,
            alignment: .leading
        )
        #expect(leadingWider == NSPoint(x: 0, y: 34))

        let trailingWider = FrostDropdownLayout.menuOrigin(
            bounds: bounds,
            menuWidth: 180,
            alignment: .trailing
        )
        #expect(trailingWider == NSPoint(x: -60, y: 34))
        #expect(trailingWider.x + 180 == bounds.width)

        let trailingNarrower = FrostDropdownLayout.menuOrigin(
            bounds: bounds,
            menuWidth: 90,
            alignment: .trailing
        )
        #expect(trailingNarrower == NSPoint(x: 0, y: 34))
    }

    @Test func buildMenuPreservesCheckmarksIconsSeparatorsEnabledStateAndActions() throws {
        final class Receiver: NSObject {
            @objc func handle(_ sender: NSMenuItem) {
                guard let box = sender.representedObject as? FrostMenuActionBox else { return }
                box.handler()
            }
        }

        let sourceIcon = NSImage(size: NSSize(width: 24, height: 24))
        var invokedTitle: String?
        let receiver = Receiver()

        let menu = FrostDropdownLayout.buildMenu(
            entries: [
                .item(title: "First", image: sourceIcon, isSelected: true) {
                    invokedTitle = "First"
                },
                .separator,
                .item(title: "Disabled", isEnabled: false) {
                    invokedTitle = "Disabled"
                },
                .item(title: "Third") {
                    invokedTitle = "Third"
                },
            ],
            minimumWidth: 132,
            target: receiver,
            action: #selector(Receiver.handle(_:))
        )

        #expect(menu.minimumWidth == 132)
        #expect(menu.items.count == 4)

        let first = menu.items[0]
        #expect(first.title == "First")
        #expect(first.state == .on)
        #expect(first.isEnabled)
        #expect(first.image?.size == NSSize(width: 16, height: 16))
        #expect(sourceIcon.size == NSSize(width: 24, height: 24))

        #expect(menu.items[1].isSeparatorItem)

        let disabled = menu.items[2]
        #expect(!disabled.isEnabled)
        #expect(disabled.action == nil)
        #expect(disabled.target == nil)

        let third = menu.items[3]
        #expect(third.state == .off)
        #expect(third.isEnabled)
        let selector = try #require(third.action)
        _ = (third.target as? NSObject)?.perform(selector, with: third)
        #expect(invokedTitle == "Third")
    }

    @Test func hostedDropdownExposesPopUpButtonAccessibility() throws {
        let dropdown = FrostDropdown(
            entries: [
                .item(title: "NetEase Music", isSelected: false) {},
                .item(title: "Apple Music", isSelected: true) {},
            ],
            chrome: .controlCenter,
            alignment: .trailing,
            indicator: .picker,
            accessibilityLabel: "Preferred Player",
            accessibilityValue: "Apple Music"
        ) {
            Text("Apple Music")
                .font(.system(size: 12.5))
        }

        let host = NSHostingView(rootView: dropdown)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()

        #expect(host.fittingSize.height == 28)

        let trigger = try #require(findSubview(ofType: DropdownTriggerNSView.self, in: host))
        #expect(trigger.isFlipped)
        #expect(trigger.acceptsFirstMouse(for: nil))
        #expect(trigger.isAccessibilityElement())
        #expect(trigger.accessibilityRole() == .popUpButton)
        #expect(trigger.accessibilityLabel() == "Preferred Player")
        #expect(trigger.accessibilityValue() as? String == "Apple Music")
        #expect(trigger.bounds.size.width >= 90)
        #expect(trigger.bounds.size.height == 28)
    }

    private func findSubview<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
        if let match = root as? T {
            return match
        }
        for subview in root.subviews {
            if let match = findSubview(ofType: type, in: subview) {
                return match
            }
        }
        return nil
    }
}
