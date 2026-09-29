import Foundation
import TimeSinkKit
#if DEBUG
if ProcessInfo.processInfo.arguments.contains("--design-preview") {
    RefinedPreview.run()
} else {
    TimeSinkApp.main()
}
#else
TimeSinkApp.main()
#endif
