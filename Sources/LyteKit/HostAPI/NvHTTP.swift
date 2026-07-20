import Foundation
import Security

/// HTTP transport for the GameStream/Sunshine host API.
///
/// - Plain HTTP on 47989: pairing steps 1–4, unpaired serverinfo.
/// - HTTPS on 47984: everything after pairing. TLS is mutual — we present the
///   client identity, and we pin the host certificate learned during pairing
///   (the host uses a self-signed cert; trust *is* the pin).
public final class NvHTTP: NSObject, @unchecked Sendable {
    public let address: String
    public let httpPort: Int
    public let httpsPort: Int

    private let identity: ClientIdentity?
    private let pinnedServerCertDER: Data?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 150   // getservercert blocks until PIN entry
        config.timeoutIntervalForResource = 150
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public init(address: String, httpPort: Int = 47989, httpsPort: Int = 47984,
                identity: ClientIdentity? = nil, pinnedServerCertDER: Data? = nil) {
        self.address = address
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        self.identity = identity
        self.pinnedServerCertDER = pinnedServerCertDER
    }

    public func get(_ path: String, query: [(String, String)], https: Bool) async throws -> NvXML {
        var comps = URLComponents()
        comps.scheme = https ? "https" : "http"
        comps.host = address
        comps.port = https ? httpsPort : httpPort
        comps.path = "/\(path)"
        comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = comps.url else { throw LyteError.http("bad URL for \(path)") }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LyteError.http("\(path): HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let xml = try NvXML(data: data)
        guard xml.statusCode == 200 else {
            throw LyteError.host("\(path): \(xml.statusMessage ?? "status \(xml.statusCode)")")
        }
        return xml
    }
}

extension NvHTTP: URLSessionDelegate {
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            let leafDER = SecCertificateCopyData(leaf) as Data
            if let pinned = pinnedServerCertDER {
                if leafDER == pinned {
                    completionHandler(.useCredential, URLCredential(trust: trust))
                } else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            } else {
                // Pre-pin phase (final pairing handshake): accept the self-signed
                // cert we were just handed over the pairing channel.
                completionHandler(.useCredential, URLCredential(trust: trust))
            }
        case NSURLAuthenticationMethodClientCertificate:
            guard let identity, let secIdentity = try? identity.secIdentity() else {
                return completionHandler(.performDefaultHandling, nil)
            }
            completionHandler(.useCredential,
                              URLCredential(identity: secIdentity, certificates: nil, persistence: .forSession))
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
