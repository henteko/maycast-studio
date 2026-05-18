import ArgumentParser
import Foundation

@main
struct Maycast: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "maycast",
        abstract: "Maycast Studio command-line interface.",
        version: "0.0.1",
        subcommands: [
            InitCommand.self,
            ImportCommand.self,
            TranscribeCommand.self,
            SliceCommand.self,
            MixCommand.self,
            ListCommand.self,
            InspectCommand.self,
            RevertCommand.self,
            ShowCommand.self,
        ]
    )
}
