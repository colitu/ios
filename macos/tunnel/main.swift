import Foundation
import NetworkExtension

// The packet tunnel runs as a system extension in the direct (Developer ID)
// macOS build: the process starts here, not through an app-extension host.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

dispatchMain()
