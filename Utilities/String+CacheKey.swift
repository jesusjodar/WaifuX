import Foundation
import CryptoKit

extension String {
    /// Preserve the existing image cache filenames after retiring the video cache.
    var md5: String {
        let hash = Insecure.MD5.hash(data: Data(utf8))
        return hash.map { String(format: "%02hhx", $0) }.joined()
    }
}
