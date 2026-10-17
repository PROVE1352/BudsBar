import Foundation

// `BudsBar --cli …` runs the debugging CLI; anything else starts the menu bar app.
let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--cli") {
    CLI.run(Array(arguments[(index + 1)...]))
    RunLoop.main.run()
} else {
    BudsBarApp.main()
}
