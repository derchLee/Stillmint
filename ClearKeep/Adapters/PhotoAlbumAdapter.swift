import Foundation
@preconcurrency import Photos

enum PhotoAlbumAdapter {
    /// Full access is required to prove arbitrary protected-album membership.
    static func snapshot() -> AlbumSnapshot {
        snapshot(access: PHPhotoLibrary.authorizationStatus(for: .readWrite), fullSnapshot: fetchFullSnapshot)
    }
    static func snapshot(access: PHAuthorizationStatus, fullSnapshot: () -> AlbumSnapshot) -> AlbumSnapshot {
        guard access == .authorized else { return .init(fullAccess: false) }
        return fullSnapshot()
    }
    private static func fetchFullSnapshot() -> AlbumSnapshot {
        var members: [String: Set<String>] = [:], titles: [String: String] = [:]
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        collections.enumerateObjects { collection, _, _ in
            var ids = Set<String>()
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
            members[collection.localIdentifier] = ids
            titles[collection.localIdentifier] = collection.localizedTitle ?? "Untitled album"
        }
        return .init(fullAccess: true, membersByAlbumID: members, titlesByAlbumID: titles)
    }
}
