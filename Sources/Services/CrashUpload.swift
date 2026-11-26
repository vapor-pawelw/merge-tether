import Foundation

final class CrashUpload: Sendable {
    private let destination: CrashReportingDestination
    private let session: URLSession

    init(destination: CrashReportingDestination) {
        self.destination = destination
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration, delegate: CrashUploadDelegate(), delegateQueue: nil)
    }

    func send(_ envelope: CrashReport.Envelope) async -> Bool {
        var request = URLRequest(url: destination.endpoint)
        request.httpMethod = "POST"
        request.httpBody = envelope.body
        request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
        request.setValue("Sentry sentry_version=7, sentry_client=mergetether/1, sentry_key=\(destination.publicKey)",
                         forHTTPHeaderField: "X-Sentry-Auth")
        guard !Task.isCancelled,
              let (_, response) = try? await session.data(for: request), let response = response as? HTTPURLResponse else {
            return false
        }
        return (200..<300).contains(response.statusCode)
    }

    func cancel() { session.invalidateAndCancel() }
}

private final class CrashUploadDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
