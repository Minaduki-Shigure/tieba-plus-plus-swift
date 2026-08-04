import CryptoKit
import Foundation

enum TiebaFormSigner {
  static let appSalt = "tiebaclient!!!"

  static func signature(for fields: [(String, String)]) -> String {
    let source = fields.sorted {
      $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
    }
    .map { "\($0.0)=\($0.1)" }
    .joined() + appSalt
    let digest = Insecure.MD5.hash(data: Data(source.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  static func encodedBody(for fields: [(String, String)]) -> Data? {
    var components = URLComponents()
    components.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
    // Form decoders treat a literal plus as a space.
    let query = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    return query?.data(using: .utf8)
  }
}
