// Version.swift
// ::rtemis-afm::
// 2026- EDG rtemis.org

/// Package-wide constants.
///
/// Swift has no built-in notion of a "package version" at run time, so the
/// version string lives here and is reported by `/health`, `/v1/models` and
/// `rtemis-afm version`. Bump it together with the git tag (`v0.1.0`).
public enum RtemisAFM {
    /// The bridge's own version, in semantic-versioning form.
    public static let version = "0.1.0"

    /// The identifier under which the on-device model is served. rtemislive
    /// asks for this id; `system` is also accepted for parity with Apple's
    /// own `fm serve`.
    public static let modelID = "afm"

    /// Aliases accepted in the request's `model` field.
    public static let acceptedModelIDs: Set<String> = [modelID, "system"]

    /// The port the bridge listens on unless `--port` says otherwise.
    /// rtemislive's Apple Intelligence provider defaults to the same value.
    public static let defaultPort = 1977
}
