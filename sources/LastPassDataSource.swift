//
//  LastPassDataSource.swift
//  iTerm2SharedARC
//
//  Created by George Nachman on 3/20/22.
//

import Foundation

class LastPassDataSource: CommandLinePasswordDataSource {
    enum LPError: Error {
        case unusableCLI
        case runtime
        case badOutput
        case syncFailed
        case canceledByUser
        case timedOut
        case needsLogin
    }

    private struct ErrorHandler {
        var requestedAuthentication = false

        mutating func handleError(_ data: Data?) throws -> Data? {
            guard let data = data else {
                return nil
            }
            if let string = String(data: data, encoding: .utf8), string.contains("lpass login") {
                throw LPError.needsLogin
            }
            if requestedAuthentication {
                return nil
            }
            requestedAuthentication = true
            guard let password = ModalPasswordAlert("Enter your LastPass master password:").run(window: nil) else {
                throw LPError.canceledByUser
            }
            return (password + "\n").data(using: .utf8)
        }
    }

    private struct LastPassBasicCommandRecipe<Inputs, Outputs>: Recipe {
        private let commandRecipe: CommandRecipe<Inputs, Outputs>
        init(_ args: [String],
             timeout: TimeInterval? = nil,
             outputTransformer: @escaping (Output) throws -> Outputs) {
            var errorHandler = ErrorHandler()
            commandRecipe = CommandRecipe { _ in
                let command = InteractiveCommand(command: LastPassUtils.pathToCLI,
                                                 args: args,
                                                 env: LastPassUtils.basicEnvironment,
                                                 handleStdout: { _ in nil },
                                                 handleStderr: { data throws in return try errorHandler.handleError(data) },
                                                 handleTermination: { _, _ in })
                if let timeout = timeout {
                    command.deadline = Date(timeIntervalSinceNow: timeout)
                }
                return command
            } recovery: { error throws in
                throw error
            } outputTransformer: { output throws in
                if output.timedOut {
                    throw LPError.timedOut
                }
                if output.returnCode != 0 {
                    throw LPError.runtime
                }
                return try outputTransformer(output)
            }
        }

        func transform(inputs: Inputs) throws -> Outputs {
            return try commandRecipe.transform(inputs: inputs)
        }

        private func handleError(_ data: Data) {

        }
    }

    private struct LastPassDynamicCommandRecipe<Inputs, Outputs>: Recipe {
        private let commandRecipe: CommandRecipe<Inputs, Outputs>

        init(inputTransformer: @escaping (Inputs) throws -> (CommandLinePasswordDataSourceExecutableCommand),
             outputTransformer: @escaping (Output) throws -> Outputs) {
            commandRecipe = CommandRecipe<Inputs, Outputs> { inputs throws -> CommandLinePasswordDataSourceExecutableCommand in
                return try inputTransformer(inputs)
            } recovery: { error throws in
                throw error
            } outputTransformer: { output throws -> Outputs in
                if output.returnCode != 0 {
                    throw LPError.runtime
                }
                return try outputTransformer(output)
            }
        }

        func transform(inputs: Inputs) throws -> Outputs {
            return try commandRecipe.transform(inputs: inputs)
        }
    }

    private var listAccountsRecipe: AnyRecipe<Void, [Account]> {
        let args = ["ls", "--format=%ai\t%an\t%au", "iTerm2"]
        let recipe = LastPassBasicCommandRecipe<Void, [Account]>(args, timeout: 5) { output in
            guard let string = String(data: output.stdout, encoding: .utf8) else {
                throw LPError.badOutput
            }
            let lines = string.components(separatedBy: "\n")
            return lines.compactMap { line -> Account? in
                let parts = line.components(separatedBy: "\t")
                guard parts.count == 3 else {
                    return nil
                }
                if parts[0] == "0" {
                    // Unsynced accounts are not safe because they don't have unique identifiers.
                    return nil
                }
                return Account(identifier: AccountIdentifier(value: parts[0]),
                               userName: parts[2],
                               accountName: parts[1])
            }
        }
        return wrap("The account list could not be fetched.", AnyRecipe(recipe))
    }

    private var getPasswordRecipe: AnyRecipe<AccountIdentifier, String> {
        let recipe = LastPassDynamicCommandRecipe<AccountIdentifier, String> {
            let args = ["show", "--password", $0.value]
            return Command(command: LastPassUtils.pathToCLI,
                           args: args,
                           env: LastPassUtils.basicEnvironment,
                    stdin: nil)
        } outputTransformer: { output in
            if output.returnCode != 0 {
                throw LPError.runtime
            }
            guard let string = String(data: output.stdout, encoding: .utf8) else {
                throw LPError.badOutput
            }
            return string.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }
        return wrap("The password could not be fetched.", AnyRecipe(recipe))
    }

    private var setPasswordRecipe: AnyRecipe<SetPasswordRequest, Void> {
        let recipe = LastPassDynamicCommandRecipe<SetPasswordRequest, Void> {
            let args = ["edit", "--non-interactive", "--password", $0.accountIdentifier.value]
            let command = InteractiveCommand(command: LastPassUtils.pathToCLI,
                                             args: args,
                                             env: LastPassUtils.basicEnvironment,
                                             handleStdout: { _ in nil },
                                             handleStderr: { _ in nil },
                                             handleTermination: { _, _ in })
            let dataToWrite = ($0.newPassword + "\n").data(using: .utf8)!
            command.didLaunch = { () -> () in
                command.write(dataToWrite) {
                    command.closeStdin()
                }
            }
            return command
        } outputTransformer: { output in
            if output.returnCode != 0 {
                throw LPError.runtime
            }
        }
        return wrap("The password could not be set.", AnyRecipe(recipe))
    }

    private var deleteRecipe: AnyRecipe<AccountIdentifier, Void> {
        let recipe = LastPassDynamicCommandRecipe<AccountIdentifier, Void> {
            let args = ["rm", $0.value]
            return Command(command: LastPassUtils.pathToCLI,
                           args: args,
                           env: LastPassUtils.basicEnvironment,
                           stdin: nil)
        } outputTransformer: { output in
            if output.returnCode != 0 {
                throw LPError.runtime
            }
        }
        return wrap("The account could not be deleted", AnyRecipe(recipe))
    }

    private var addAccountRecipe: AnyRecipe<AddRequest, AccountIdentifier> {
        let addRecipe = LastPassDynamicCommandRecipe<AddRequest, Void> {
            let args = ["add", "iTerm2/" + $0.accountName, "--non-interactive"]
            let input = "Username: \($0.userName)\nPassword: \($0.password)"
            let command = InteractiveCommand(command: LastPassUtils.pathToCLI,
                                      args: args,
                                      env: LastPassUtils.basicEnvironment,
                                      handleStdout: { _ in nil },
                                      handleStderr: { _ in nil },
                                      handleTermination: { _, _ in })
            let dataToWrite = input.data(using: .utf8)!
            command.didLaunch = { () -> () in
                command.write(dataToWrite) {
                    command.closeStdin()
                }
            }
            return command
        } outputTransformer: { output in
            if output.returnCode != 0 {
                throw LPError.runtime
            }
        }

        let syncRecipe = LastPassBasicCommandRecipe<(AddRequest, Void), Void>(["sync", "now"],
                                                                              timeout: 5) { _ in }

        let showRecipe = LastPassDynamicCommandRecipe<(AddRequest, Void), AccountIdentifier> { tuple in
            let args = ["show", "--id", "iTerm2/" + tuple.0.accountName]
            return Command(command: LastPassUtils.pathToCLI,
                           args: args,
                           env: LastPassUtils.basicEnvironment,
                           stdin: nil)
        } outputTransformer: { output in
            if output.returnCode != 0 {
                throw LPError.runtime
            }
            guard let string = String(data: output.stdout, encoding: .utf8) else {
                throw LPError.badOutput
            }
            let lines = string.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            guard lines.count >= 1 else {
                throw LPError.runtime
            }
            let idString = lines.last!
            guard idString != "0" else {
                throw LPError.syncFailed
            }
            return AccountIdentifier(value: idString)
        }

        let addSyncSequence:
        SequenceRecipe<
            LastPassDynamicCommandRecipe<AddRequest, Void>,
                LastPassBasicCommandRecipe<(AddRequest, Void), Void>> = SequenceRecipe(addRecipe, syncRecipe)
        let sequence = SequenceRecipe(addSyncSequence, showRecipe)
        return wrap("The account could not be added.", AnyRecipe(sequence))
    }

    func wrap<Inputs, Outputs>(_ message: String, _ recipe: AnyRecipe<Inputs, Outputs>) -> AnyRecipe<Inputs, Outputs> {
        return AnyRecipe(CatchRecipe(recipe, errorHandler: { error in
            if error as? LPError == LPError.timedOut {
                let alert = NSAlert()
                alert.messageText = "Timeout"
                alert.informativeText = "The LastPass service took too long to respond. \(message)"
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            } else if error as? LPError == LPError.needsLogin {
                LastPassUtils.showNotLoggedInMessage()
            }
            NSLog("\(error)")
        }))
    }
    var configuration: Configuration {
        lazy var value = {
            Configuration(listAccountsRecipe: listAccountsRecipe,
                          getPasswordRecipe: getPasswordRecipe,
                          setPasswordRecipe: setPasswordRecipe,
                          deleteRecipe: deleteRecipe,
                          addAccountRecipe: addAccountRecipe)
        }()
        return value
    }
}

extension LastPassDataSource: PasswordManagerDataSource {
    var accounts: [PasswordManagerAccount] {
        return standardAccounts(configuration)
    }

    var autogeneratedPasswordsOnly: Bool {
        false
    }

    func checkAvailability() -> Bool {
        let command = Command(command: LastPassUtils.pathToCLI,
                              args: ["status", "--color=never"],
                              env: LastPassUtils.basicEnvironment,
                              stdin: nil)
        _ = try? command.exec()
        if command.output!.returnCode == 0 {
            return true
        }
        if String(data: command.output!.stdout, encoding: .utf8)?.hasPrefix("Not logged in") ?? false {
            LastPassUtils.showNotLoggedInMessage()
        }
        return false
    }

    func add(userName: String, accountName: String, password: String) throws -> PasswordManagerAccount {
        return try standardAdd(configuration,
                               userName: userName,
                               accountName: accountName,
                               password: password)
    }

    func resetErrors() {
    }

    func reload() {
    }
}

class LastPassUtils {
    static let basicEnvironment = ["HOME": NSHomeDirectory(),
                                   "LPASS_ASKPASS": pathToAskpass]
    static var pathToAskpass: String {
        return Bundle.main.path(forResource: "askpass", ofType: "sh")!
    }

    private static var _customPathToCLI: String? = nil
    private(set) static var usable: Bool? = nil

    static var pathToCLI: String {
        if let customPath = _customPathToCLI {
            return customPath
        }
        let normalPaths = ["/opt/local/bin/lpass", "/opt/homebrew/bin/lpass"]
        lazy var existingNormalPath = {
            normalPaths.first { checkUsability($0) }
        }()
        if let normalPath = existingNormalPath {
            usable = true
            return normalPath
        }
        while showCannotFindCLIMessage() {
            _customPathToCLI = askUserToFindCLI()
            guard let path = _customPathToCLI else {
                break
            }
            usable = checkUsability(path)
            if usable == true {
                break
            }
        }
        return _customPathToCLI ?? normalPaths[0]
    }

    static func throwIfUnusable() throws {
        _ = pathToCLI
        if usable == false {
            throw LastPassDataSource.LPError.unusableCLI
        }
    }

    static func resetErrors() {
        if usable == false {
            usable = nil
            _customPathToCLI = nil
        }
    }
    static func checkUsability() -> Bool {
        return checkUsability(pathToCLI)
    }

    private static func checkUsability(_ path: String) -> Bool {
        return FileManager.default.fileExists(atPath: path)
    }

    static func showNotLoggedInMessage() {
        let alert = NSAlert()
        alert.messageText = "Login Needed"
        alert.informativeText = "Open a terminal window and run `lpass login your@email.address`."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Command")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.declareTypes([.string], owner: self)
            NSPasteboard.general.setString("lpass login me@example.com", forType: .string)
        }
    }

    // Returns true to show an open panel to locate it.
    private static func showCannotFindCLIMessage() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Can’t Find LastPass CLI"
        alert.informativeText = "In order to use the LastPass integration, iTerm2 needs to know where to find the CLI app named “lpass”. Select Locate to provide its location."
        alert.addButton(withTitle: "Locate")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Help")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            return false
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://iterm2.com/lastpass-cli")!)
            return false
        default:
            return false
        }
    }

    private static func askUserToFindCLI() -> String? {
        class LastPassCLIFinderOpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {
            func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
                if FileManager.default.itemIsDirectory(url.path) {
                    return true
                }
                return url.lastPathComponent == "lpass"
            }
        }
        let panel = NSOpenPanel()
        let defaultPath = ["/opt/homebrew/bin", "/opt/local/bin"].first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/local/bin"
        panel.directoryURL = URL(fileURLWithPath: defaultPath)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = [ "" ]
        let delegate = LastPassCLIFinderOpenPanelDelegate()
        return withExtendedLifetime(delegate) {
            panel.delegate = delegate
            if panel.runModal() == .OK,
                let url = panel.url,
                url.lastPathComponent == "lpass" {
                return url.path
            }
            return nil
        }
    }
}
