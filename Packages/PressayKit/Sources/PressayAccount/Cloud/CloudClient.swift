import Foundation

private struct StructuredError: Decodable {
    struct Value: Decodable { let code: String }
    let error: Value
}

/// What the OAuth issuer answers.
private struct PlainError: Decodable {
    let error: String
}

/// Typed requests against Pressay Cloud and the OAuth issuer. Holds no state.
public struct CloudClient: Sendable {
    public let configuration: CloudConfiguration
    let transport: any HTTPTransport

    public init(configuration: CloudConfiguration, transport: any HTTPTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: configuration.apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw CloudFailure("cloud_api_url_invalid")
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw CloudFailure("cloud_api_url_invalid") }
        return url
    }

    func request(_ method: String, _ url: URL, bearer: String? = nil, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    func json<Body: Encodable>(
        _ method: String, _ url: URL, body: Body, bearer: String?, headers: [String: String] = [:]
    ) throws -> URLRequest {
        var request = request(method, url, bearer: bearer, headers: headers)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    func form(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = request("POST", url)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }
        request.httpBody = Data(body.joined(separator: "&").utf8)
        return request
    }

    /// Sends a request and returns its body, or throws the server's stable error code.
    @discardableResult
    func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let failure as CloudFailure {
            throw failure
        } catch let error as URLError where error.code == .cancelled {
            // A screen that went away: nothing failed, and nobody should be told otherwise.
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudFailure.networkUnavailable
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.failure(status: response.statusCode, body: data)
        }
        return data
    }

    func decode<Response: Decodable>(_ type: Response.Type, _ request: URLRequest) async throws -> Response {
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CloudFailure.responseInvalid
        }
    }

    static func failure(status: Int, body: Data) -> CloudFailure {
        if let structured = try? JSONDecoder().decode(StructuredError.self, from: body) {
            return CloudFailure(structured.error.code)
        }
        if let plain = try? JSONDecoder().decode(PlainError.self, from: body) {
            return CloudFailure(plain.error)
        }
        return switch status {
        case 401: CloudFailure("cloud_unauthorized")
        case 403: CloudFailure("cloud_forbidden")
        case 404: CloudFailure("cloud_not_found")
        case 409: CloudFailure("cloud_conflict")
        case 422: CloudFailure("cloud_invalid_request")
        case 429: CloudFailure("cloud_rate_limited")
        case 503: CloudFailure.unavailable
        default: CloudFailure("cloud_request_failed")
        }
    }
}
