/// Shared cross-cutting error set.
///
/// Individual modules may define additional errors; these cover the common cases returned across the public API.
pub const Error = error{
    /// A requested path or resource was not found.
    NotFound,
    /// The caller lacks permission to access the resource.
    PermissionDenied,
    /// Expected a directory but found something else.
    NotADirectory,
    /// Expected a file but found something else.
    NotAFile,
    /// The resource already exists and the operation does not allow overwriting.
    AlreadyExists,
    /// The provided path is syntactically invalid.
    InvalidPath,
    /// The requested feature is not available on the current operating system.
    Unsupported,
    /// A required runtime resource is unavailable (e.g. `XDG_RUNTIME_DIR` not set).
    NotAvailable,
};
