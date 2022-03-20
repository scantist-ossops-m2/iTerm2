//
//  PasswordManagerDataSource.swift
//  iTerm2SharedARC
//
//  Created by George Nachman on 3/18/22.
//

import Foundation

@objc
protocol PasswordManagerAccount: AnyObject {
    @objc var accountName: String { get }
    @objc var userName: String { get }
    @objc var displayString: String { get }
    @objc(password:) func password() throws -> String
    @objc(setPassword:error:) func set(password: String) throws
    @objc(delete:) func delete() throws
    @objc(matchesFilter:) func matches(filter: String) -> Bool
}

@objc
protocol PasswordManagerDataSource: AnyObject {
    var accounts: [PasswordManagerAccount] { get }
    var autogeneratedPasswordsOnly: Bool { get }
    func checkAvailability() -> Bool
    @objc(addUserName:accountName:password:error:) func add(userName: String,
                                                            accountName: String,
                                                            password: String) throws -> PasswordManagerAccount
    func resetErrors()
}

extension PasswordManagerAccount {
    func _matches(filter: String) -> Bool {
        if filter.isEmpty {
            return true
        }
        return [accountName, userName].anySatisfies {
            $0.containsCaseInsensitive(filter)
        }
    }
}

