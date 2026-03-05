import ArgumentParser
import Foundation

struct VPhoneCLI: ParsableCommand {
    nonisolated(unsafe) static var configuration = CommandConfiguration(
        commandName: "vphone",
        abstract: "Boot a virtual iPhone",
    )

    @Option(help: "Path to the AVPBooter / ROM binary")
    var rom: String

    @Option(help: "Path to the disk image")
    var disk: String

    @Option(help: "Path to NVRAM storage (created/overwritten)")
    var nvram: String = "nvram.bin"

    @Option(help: "Number of CPU cores")
    var cpu: Int = 4

    @Option(help: "Memory size in MB")
    var memory: Int = 4096

    @Option(help: "Path to write serial console log file")
    var serialLog: String? = nil

    @Flag(help: "Stop VM on guest panic")
    var stopOnPanic: Bool = false

    @Flag(help: "Stop VM on fatal error")
    var stopOnFatalError: Bool = false

    @Option(help: "Path to SEP storage file (created if missing)")
    var sepStorage: String = "sep_storage.bin"

    @Option(help: "Path to SEP ROM binary")
    var sepRom: String? = nil

    @Flag(help: "Boot into DFU mode")
    var dfu: Bool = false

    @Flag(help: "Run without GUI (headless)")
    var noGraphics: Bool = false

    @Flag(help: "No keyboard")
    var noKeyboard: Bool = false

    @Flag(help: "Start a fake USB HID keyboard via IOUSBHostControllerInterface")
    var fakeUSBKeyboard: Bool = false

    // Execution is handled by VPhoneAppDelegate; main.swift calls parseOrExit()
    // and never invokes run().
    mutating func run() throws {}
}
