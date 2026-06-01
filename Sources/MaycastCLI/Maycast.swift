import ArgumentParser
import Foundation

@main
struct Maycast: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "maycast",
        abstract: "Maycast Studio command-line interface.",
        version: MaycastVersion.current,
        subcommands: [
            InitCommand.self,
            ImportCommand.self,
            TranscribeCommand.self,
            SliceCommand.self,
            MixCommand.self,
            ChapterCommand.self,
            ListCommand.self,
            InspectCommand.self,
            RevertCommand.self,
            UndoCommand.self,
            RedoCommand.self,
            ShowCommand.self,
        ]
    )
}
