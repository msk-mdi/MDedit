import Foundation
import Testing
import WebKit
@testable import MdEdit

/// The bookkeeping that lets the typesetter outlive a dead or stuck page.
/// What it does with a live web view (reloading the page, the timeout
/// itself) is not covered here.
@Suite("Typesetter recovery")
struct TypesetterRecoveryTests {
    private func request(_ source: String, _ kind: Typesetter.Kind = .inlineMath) -> Typesetter.Request {
        Typesetter.Request(kind: kind, source: source, fontSize: 16, color: "#000", dark: false, width: 600)
    }

    @Test("An answer lands once, for the request in flight")
    func landing() {
        var flight = Typesetter.Flight()
        #expect(flight.request == nil)
        let ticket = flight.begin(request("a"))
        #expect(flight.request == request("a"))
        #expect(flight.isCurrent(ticket))
        #expect(flight.land(ticket) == request("a"))
        #expect(flight.request == nil)
        // The same answer a second time is nobody's.
        #expect(!flight.isCurrent(ticket))
        #expect(flight.land(ticket) == nil)
    }

    @Test("A late answer from a page torn down cannot land on the next request")
    func staleTicket() {
        var flight = Typesetter.Flight()
        let stuck = flight.begin(request("stuck"))
        // Timed out: landed as failed, its page thrown away.
        #expect(flight.land(stuck) == request("stuck"))
        let next = flight.begin(request("next"))
        #expect(next != stuck)
        #expect(!flight.isCurrent(stuck))
        #expect(flight.land(stuck) == nil)
        #expect(flight.request == request("next"))
        #expect(flight.land(next) == request("next"))
    }

    @Test("The answer of a request lost with its process is stale too")
    func staleAfterCrash() {
        var flight = Typesetter.Flight()
        let first = flight.begin(request("a"))
        #expect(flight.crash()?.retry == true)
        #expect(!flight.isCurrent(first))
        // Sent again on the new page, under a new ticket.
        let second = flight.begin(request("a"))
        #expect(flight.land(first) == nil)
        #expect(flight.land(second) == request("a"))
    }

    @Test("A process dying with nothing in flight blames no request")
    func idleCrash() {
        var flight = Typesetter.Flight()
        #expect(flight.crash() == nil)
        let ticket = flight.begin(request("a"))
        _ = flight.land(ticket)
        #expect(flight.crash() == nil)
    }

    @Test("A source is retried after the process dies, and given up on once it has died with it too often")
    func crashLimit() {
        var flight = Typesetter.Flight()
        for attempt in 1...Typesetter.Flight.crashLimit {
            _ = flight.begin(request("deadly"))
            let lost = flight.crash()
            #expect(lost?.request == request("deadly"))
            #expect(lost?.retry == (attempt < Typesetter.Flight.crashLimit))
            #expect(flight.request == nil)
        }
        // Given up on, it starts afresh if asked for again.
        _ = flight.begin(request("deadly"))
        #expect(flight.crash()?.retry == true)
    }

    @Test("Deaths are counted per request, and forgotten once it is typeset or cancelled")
    func crashCounts() {
        var flight = Typesetter.Flight()
        _ = flight.begin(request("a"))
        #expect(flight.crash()?.retry == true)
        // Another request's death is its own first.
        _ = flight.begin(request("b"))
        #expect(flight.crash()?.retry == true)

        // `a` succeeds on its second try: a later death counts from nothing.
        let ticket = flight.begin(request("a"))
        #expect(flight.land(ticket) == request("a"))
        _ = flight.begin(request("a"))
        #expect(flight.crash()?.retry == true)

        // `b` was cancelled while waiting for its second try.
        flight.forget(request("b"))
        _ = flight.begin(request("b"))
        #expect(flight.crash()?.retry == true)
    }

    @Test("Only a JavaScript exception is a verdict on the source")
    func verdicts() {
        #expect(Typesetter.isVerdict(WKError(.javaScriptExceptionOccurred)))
        #expect(!Typesetter.isVerdict(WKError(.webContentProcessTerminated)))
        #expect(!Typesetter.isVerdict(WKError(.webViewInvalidated)))
        // What a call in flight fails with when its process is killed.
        #expect(!Typesetter.isVerdict(WKError(.javaScriptResultTypeIsUnsupported)))
        #expect(!Typesetter.isVerdict(WKError(.unknown)))
        #expect(!Typesetter.isVerdict(CocoaError(.fileNoSuchFile)))
    }

    @Test("Diagrams are given longer than formulas")
    func timeouts() {
        #expect(Typesetter.timeout(for: .inlineMath) == Typesetter.timeout(for: .displayMath))
        #expect(Typesetter.timeout(for: .diagram) > Typesetter.timeout(for: .displayMath))
    }
}
