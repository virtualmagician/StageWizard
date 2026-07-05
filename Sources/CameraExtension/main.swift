import Foundation
import CoreMediaIO

// Entry point of the "StageWizard Camera" system extension.
let providerSource = CameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
