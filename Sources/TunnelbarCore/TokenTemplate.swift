import Foundation

/// The Cloudflare dashboard link for creating an API token.
///
/// Cloudflare has no OAuth flow that would let a third-party app mint a token,
/// so this is as close to one click as the platform allows: the dashboard opens
/// on the token page with a name filled in. Everything after the paste —
/// verification, account lookup, storage — Tunnelbar does itself.
///
/// ## Why the permission is not preselected
///
/// The dashboard's `permissionGroupKeys` parameter takes short keys like `dns`
/// or `workers_scripts`. Cloudflare documents neither the key list nor a way to
/// obtain it: the permission-groups API returns GUIDs and display names, not
/// these keys, so there is no way to look one up at runtime either. The
/// historical guess `argo_tunnel` was tried and produced an empty permission
/// list — a button that opens the right page with nothing selected and no error
/// explaining why, which is worse than not preselecting at all.
///
/// So the link carries only a name, and the UI states the exact permission to
/// choose. A reliable instruction beats an unreliable shortcut.
public enum TokenTemplate {
    /// What the user must select in the dashboard, spelled as the dashboard
    /// spells it.
    public static let requiredPermission = "Account → Cloudflare Tunnel → Read"

    public static func creationURL(name: String = "Tunnelbar") -> URL {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? name
        return URL(string: "https://dash.cloudflare.com/profile/api-tokens?name=\(encoded)")!
    }
}
