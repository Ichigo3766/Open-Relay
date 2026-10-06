import Foundation

extension String {
    /// `encodeURIComponent` for a single URL path segment: "/", "?", "#" and "%" are encoded too,
    /// so an id such as "org/model:latest" stays ONE segment (`org%2Fmodel:latest`), which is
    /// what the server's `{model_id}` routes and the web client expect.
    var encodedPathSegment: String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
