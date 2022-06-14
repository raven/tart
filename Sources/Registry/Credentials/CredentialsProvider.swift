import Foundation

enum CredentialsProviderError: Error {
    case Failed(message: String)
}

public protocol CredentialsProvider {
    func retrieve(host: String) throws -> (String, String)?
    func store(host: String, user: String, password: String) throws
}
