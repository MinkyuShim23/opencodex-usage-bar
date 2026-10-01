// Give one file a custom Finder icon: swift tools/set-file-icon.swift <image> <file>
//
// System Settings draws a launch agent with the icon of its executable, not of the app bundle
// around it, so a locally signed app shows up as a generic "exec" tile. A custom icon on the
// executable itself fixes that. It lives in extended attributes, so the code signature is untouched.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let image = NSImage(contentsOfFile: args[1]) else {
    print("usage: set-file-icon <image> <file>")
    exit(2)
}
exit(NSWorkspace.shared.setIcon(image, forFile: args[2], options: []) ? 0 : 1)
