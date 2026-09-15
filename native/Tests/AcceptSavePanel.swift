// UI smoke driver: presses Save only in this test process and fixture filename.
import ApplicationServices
import Foundation

guard CommandLine.arguments.count == 3, let pid = pid_t(CommandLine.arguments[1]), pid > 0 else { exit(64) }
guard AXIsProcessTrusted() else {
    fputs("Native save-panel smoke requires existing Accessibility access.\n", stderr)
    exit(77)
}
let name = CommandLine.arguments[2]
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}
func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 12 else { return [] }
    return [element] + children(element).flatMap { descendants($0, depth: depth + 1) }
}
let application = AXUIElementCreateApplication(pid)
for _ in 0..<100 {
    let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
    for sheet in windows {
        let elements = descendants(sheet)
        guard elements.contains(where: {
            attribute($0, kAXRoleAttribute) as? String == kAXTextFieldRole
                && attribute($0, kAXValueAttribute) as? String == name
        }) else { continue }
        for button in elements where attribute(button, kAXRoleAttribute) as? String == kAXButtonRole
            && attribute(button, kAXTitleAttribute) as? String == "Save"
            && attribute(button, kAXEnabledAttribute) as? Bool == true {
            if AXUIElementPerformAction(button, kAXPressAction as CFString) == .success { exit(0) }
        }
    }
    Thread.sleep(forTimeInterval: 0.1)
}
fputs("Fixture save sheet was not ready.\n", stderr)
exit(1)
