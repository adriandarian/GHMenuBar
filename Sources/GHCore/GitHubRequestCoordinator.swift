import Foundation

/// Only account names, request counts, and quota numbers are retained. HTTP bodies, URLs, and credentials
/// from gh's trace are deliberately excluded from persisted diagnostics.
public struct GitHubHTTPObservation: Codable, Equatable, Sendable {
    public var date: Date
    public var resource: String
    public var status: Int?
    public var limit: Int?
    public var remaining: Int?
    public var resetAt: Date?
    public var retryAfter: TimeInterval?
    public var graphQLCost: Int?
    public var cached = false
    public var account: String?

    public init(date: Date = Date(), resource: String, status: Int? = nil,
                limit: Int? = nil, remaining: Int? = nil, resetAt: Date? = nil,
                retryAfter: TimeInterval? = nil, graphQLCost: Int? = nil) {
        self.date = date
        self.resource = resource
        self.status = status
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
        self.retryAfter = retryAfter
        self.graphQLCost = graphQLCost
    }
}

public struct GitHubAPIUsage: Sendable {
    public let observations: [GitHubHTTPObservation]

    public var restRequests: Int { observations.filter { $0.resource != "graphql" && !$0.cached }.count }
    public var graphQLRequests: Int { observations.filter { $0.resource == "graphql" && !$0.cached }.count }
    public var summary: String { "REST \(restRequests) · GraphQL \(graphQLRequests)" }
    public var detail: String {
        let quotas = ["core", "graphql"].compactMap { resource -> String? in
            guard let value = observations.last(where: { $0.resource == resource }),
                  let remaining = value.remaining, let limit = value.limit else { return nil }
            return "\(resource == "core" ? "REST" : "GraphQL") \(remaining)/\(limit) remaining at \(value.date.formatted(date: .omitted, time: .shortened))"
        }
        return "This app’s HTTP requests in the last hour, including pagination and retries. "
            + (quotas.isEmpty ? "Account quota has not been observed yet." : "Last observed account quota: " + quotas.joined(separator: "; ") + ".")
            + " GraphQL request counts are not point costs; gh does not expose the cost of its PR queries."
    }
}

/// All app-owned CLI clients (including settings) share this queue and cooldown.
public actor GitHubRequestCoordinator {
    public static let shared = GitHubRequestCoordinator(persistence: .standard)
    public static let diagnosticsKey = "GHMenuBar.apiUsage.v1"
    private let persistence: UserDefaults?
    private var observations: [GitHubHTTPObservation]
    private var blockedUntil: [String: Date] = [:]
    private var secondaryFailures = 0
    private var isRunning = false
    private var account: String?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(persistence: UserDefaults? = nil) {
        self.persistence = persistence
        observations = persistence?.data(forKey: Self.diagnosticsKey)
            .flatMap { try? JSONDecoder().decode([GitHubHTTPObservation].self, from: $0) } ?? []
    }

    public func useAccount(_ login: String) {
        let login = login.lowercased()
        guard account != login else { return }
        account = login
        blockedUntil = [:]
        secondaryFailures = 0
        // Restore only this account's latest quota observations after a relaunch
        // or account switch. A previous account's cooldown must not leak across.
        let latest = observations.filter { $0.account == login && !$0.cached }
        for value in latest {
            if let remaining = value.remaining, let reset = value.resetAt {
                blockedUntil[value.resource] = remaining <= Self.reserve(for: value) && reset > Date() ? reset : nil
            }
            if let delay = value.retryAfter, value.status == 429 || value.status == 403 {
                let retryAt = value.date.addingTimeInterval(delay)
                if retryAt > Date() { blockedUntil["all"] = retryAt }
            }
        }
    }

    public func usage(now: Date = Date()) -> GitHubAPIUsage {
        GitHubAPIUsage(observations: observations.filter { now.timeIntervalSince($0.date) < 3_600 })
    }

    public func run(arguments: [String], runner: any ProcessRunning) async throws -> ProcessResult {
        if isRunning {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isRunning = true
        }
        defer {
            if waiters.isEmpty { isRunning = false } else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        let resource = Self.resource(for: arguments)
        if let resource {
            try checkBudget(resource: resource)
        }
        let requestAccount = account
        let result = try await runner.run(executable: "gh", arguments: arguments)
        record(result.httpObservations, account: requestAccount)
        if let resource, Self.isRateLimitFailure(result) {
            let rateObservation = result.httpObservations.last(where: {
                $0.remaining == 0 || $0.retryAfter != nil || $0.status == 429 || $0.status == 403
            })
            let now = Date()
            let primary = rateObservation?.remaining == 0
            let bucket = primary ? (rateObservation?.resource ?? resource) : "all"
            secondaryFailures = min(secondaryFailures + 1, 6)
            let retryAt = primary ? (rateObservation?.resetAt ?? now.addingTimeInterval(60))
                : now.addingTimeInterval(rateObservation?.retryAfter ?? min(60 * pow(2, Double(secondaryFailures - 1)), 3_600))
            let resumeAt = max(retryAt, now.addingTimeInterval(1))
            if account == requestAccount { blockedUntil[bucket] = resumeAt }
            throw GitHubCLIError.rateLimited(resource: bucket, retryAt: resumeAt)
        }
        if result.exitCode == 0 { secondaryFailures = 0 }
        return result
    }

    private func checkBudget(resource: String, now: Date = Date()) throws {
        for bucket in ["all", resource] {
            if let date = blockedUntil[bucket], date > now {
                throw GitHubCLIError.rateLimited(resource: bucket, retryAt: date)
            }
        }
    }

    private func record(_ values: [GitHubHTTPObservation], account requestAccount: String?, now: Date = Date()) {
        observations.removeAll { now.timeIntervalSince($0.date) >= 3_600 }
        observations.append(contentsOf: values.map { value in
            var value = value
            value.account = requestAccount
            return value
        })
        // Bound diagnostics even if another bug causes excessive requests.
        observations = Array(observations.suffix(10_000))
        for value in values where !value.cached && account == requestAccount {
            if let reset = value.resetAt, let remaining = value.remaining {
                if remaining <= Self.reserve(for: value), reset > now {
                    // Leave a small reserve for interactive tools sharing this account.
                    blockedUntil[value.resource] = reset
                } else {
                    blockedUntil[value.resource] = nil
                }
            }
        }
        if !values.isEmpty, let data = try? JSONEncoder().encode(observations) {
            persistence?.set(data, forKey: Self.diagnosticsKey)
        }
    }

    private static func reserve(for observation: GitHubHTTPObservation) -> Int {
        min(100, max(0, (observation.limit ?? 5_000) / 50))
    }

    static func resource(for arguments: [String]) -> String? {
        guard let command = arguments.first else { return nil }
        if command == "config" { return nil }
        if command == "api" {
            if arguments.dropFirst().first == "graphql" { return "graphql" }
            return "core"
        }
        if command == "search" { return "search" }
        return "graphql"
    }

    static func isRateLimitFailure(_ result: ProcessResult) -> Bool {
        let headerFailure = result.httpObservations.contains { $0.status == 429 || ($0.status == 403 && $0.remaining == 0) }
        guard result.exitCode != 0 || headerFailure
            || (result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !result.stderr.isEmpty) else { return false }
        let output = (result.stderr + "\n" + result.stdout).lowercased()
        return output.contains("rate limit") || output.contains("rate_limit")
            || headerFailure
    }
}

/// Opt in to gh's HTTP trace only for the app's read client. The generic process
/// runner used by terminals/review tools keeps its existing environment.
public struct GitHubProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: String, arguments: [String]) async throws -> ProcessResult {
        let raw = try await DefaultProcessRunner(environmentOverrides: ["GH_DEBUG": "api", "NO_COLOR": "1"])
            .run(executable: executable, arguments: arguments)
        let trace = GitHubHTTPTrace.parse(raw.stderr)
        return ProcessResult(stdout: raw.stdout, stderr: trace.stderr, exitCode: raw.exitCode,
                             httpObservations: trace.observations)
    }
}

enum GitHubHTTPTrace {
    struct Result {
        var stderr: String
        var observations: [GitHubHTTPObservation]
    }

    static func parse(_ text: String, now: Date = Date()) -> Result {
        var observations: [GitHubHTTPObservation] = []
        var current: GitHubHTTPObservation?
        var inTrace = false
        var inResponse = false
        var body: [String] = []
        var errors: [String] = []

        func finish() {
            guard var value = current else { return }
            if let data = body.joined(separator: "\n").data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = json["data"] as? [String: Any],
               let rateLimit = response["rateLimit"] as? [String: Any] {
                value.graphQLCost = rateLimit["cost"] as? Int
            }
            observations.append(value)
            current = nil
            body = []
            inResponse = false
        }

        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("* Request at ") {
                finish()
                inTrace = true
            } else if line.hasPrefix("* Request to ") {
                inTrace = true
                current = GitHubHTTPObservation(date: now, resource: line.contains("/graphql") ? "graphql" : "core")
            } else if line.hasPrefix("* Request took ") {
                finish()
                inTrace = false
            } else if inTrace, line.hasPrefix("< HTTP/") {
                current?.status = line.split(separator: " ").dropFirst(2).first.flatMap { Int($0) }
                inResponse = true
            } else if inTrace, line.hasPrefix("< ") {
                let parts = line.dropFirst(2).split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                switch parts[0].lowercased() {
                case "x-ratelimit-resource": current?.resource = value
                case "x-ratelimit-limit": current?.limit = Int(value)
                case "x-ratelimit-remaining": current?.remaining = Int(value)
                case "x-ratelimit-reset": current?.resetAt = TimeInterval(value).map(Date.init(timeIntervalSince1970:))
                case "retry-after": current?.retryAfter = TimeInterval(value)
                case "x-from-cache", "x-gh-cache": current?.cached = value != "false" && value != "0"
                default: break
                }
            } else if inTrace {
                if inResponse { body.append(line) }
            } else if !line.hasPrefix("["), !line.hasPrefix("* ") {
                errors.append(line)
            }
        }
        finish()
        return Result(stderr: errors.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                      observations: observations)
    }
}

public enum GitHubRefreshPolicy {
    public static func interval(configured: Int, isActive: Bool) -> TimeInterval {
        TimeInterval(isActive ? configured : max(configured, 900))
    }
}
