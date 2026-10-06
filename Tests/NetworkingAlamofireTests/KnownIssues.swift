/// Alamofire transport defects listed under "Status & known issues" in the README.
///
/// Tests wrap each assertion that such a defect breaks in `XCTExpectFailure(KnownIssue.…)`. The suite stays
/// green, and once the defect is fixed the strict expectation fails, so the wrapper and the README entry get removed.
enum KnownIssue {
    static let retriedDownloadsLeak =
        "Known issue: a retried download leaves each failed attempt's file in the temporary directory"
    static let downloadCancelledDuringRetryDelayNeverFinishes =
        "Known issue: a download cancelled during a retry delay never finishes"
    static let cancellationDuringRetryDelayThrowsLastError =
        "Known issue: a request cancelled during a retry delay throws the last attempt's error, not .cancelled"
}
