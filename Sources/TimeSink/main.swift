import Foundation
import TimeSinkKit
#if DEBUG
if let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "--onboarding-frames"), flag + 1 < ProcessInfo.processInfo.arguments.count {
    OnboardingFrames.run(outdir: ProcessInfo.processInfo.arguments[flag + 1])
} else if ProcessInfo.processInfo.arguments.contains("--design-preview") {
    // `-AppleLanguages (zh-Hans)` only counts to the system when it comes
    // before the first plain argument; accept it anywhere.
    let args = ProcessInfo.processInfo.arguments
    if let index = args.firstIndex(of: "-AppleLanguages"), index + 1 < args.count {
        let list = args[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: "() ")).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        UserDefaults.standard.setVolatileDomain(["AppleLanguages": list], forName: UserDefaults.argumentDomain)
    }
    RefinedPreview.run()
} else {
    TimeSinkApp.main()
}
#else
TimeSinkApp.main()
#endif
