import Photos
import Foundation

extension PHAsset {

    // Returns original file name, useful for photos synced with iTunes
    var originalFileName: String? {
        var result: String?

        // This technique is slow
        if #available(iOS 9.0, *) {
            let resources = PHAssetResource.assetResources(for: self)
            if let resource = resources.first {
                result = resource.originalFilename
            }
        }

        return result
    }

    var fileName: String? {
        return self.value(forKey: "filename") as? String
    }

}

final class PhotoLibraryService {

    let fetchOptions: PHFetchOptions!
    let thumbnailRequestOptions: PHImageRequestOptions!
    let imageRequestOptions: PHImageRequestOptions!
    let dateFormatter: DateFormatter!
    let cachingImageManager: PHCachingImageManager!

    let contentMode = PHImageContentMode.aspectFill // AspectFit: can be smaller, AspectFill - can be larger. TODO: resize to exact size

    var cacheActive = false

    let mimeTypes = [
        "flv":  "video/x-flv",
        "mp4":  "video/mp4",
        "m3u8":	"application/x-mpegURL",
        "ts":   "video/MP2T",
        "3gp":	"video/3gpp",
        "mov":	"video/quicktime",
        "avi":	"video/x-msvideo",
        "wmv":	"video/x-ms-wmv",
        "gif":  "image/gif",
        "jpg":  "image/jpeg",
        "jpeg": "image/jpeg",
        "png":  "image/png",
        "tiff": "image/tiff",
        "tif":  "image/tiff"
    ]

    static let PERMISSION_ERROR = "Permission Denial: This application is not allowed to access Photo data."

    let dataURLPattern = try! NSRegularExpression(pattern: "^data:.+?;base64,", options: NSRegularExpression.Options(rawValue: 0))

    let assetCollectionTypes = [PHAssetCollectionType.album, PHAssetCollectionType.smartAlbum/*, PHAssetCollectionType.moment*/]

    fileprivate init() {
        fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        //fetchOptions.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        if #available(iOS 9.0, *) {
            fetchOptions.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced, .typeCloudShared]
        }

        thumbnailRequestOptions = PHImageRequestOptions()
        thumbnailRequestOptions.isSynchronous = false
        thumbnailRequestOptions.resizeMode = .exact
        thumbnailRequestOptions.deliveryMode = .highQualityFormat
        thumbnailRequestOptions.version = .current
        thumbnailRequestOptions.isNetworkAccessAllowed = false

        imageRequestOptions = PHImageRequestOptions()
        imageRequestOptions.isSynchronous = false
        imageRequestOptions.resizeMode = .exact
        imageRequestOptions.deliveryMode = .highQualityFormat
        imageRequestOptions.version = .current
        imageRequestOptions.isNetworkAccessAllowed = false

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"

        cachingImageManager = PHCachingImageManager()
    }

    class var instance: PhotoLibraryService {

        struct SingletonWrapper {
            static let singleton = PhotoLibraryService()
        }

        return SingletonWrapper.singleton

    }

    static func hasPermission() -> Bool {
        if #available(iOS 14.0, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            return status == .authorized || status == .limited
        } else {
            return PHPhotoLibrary.authorizationStatus() == .authorized
        }
    }

    func getLibrary(_ options: PhotoLibraryGetLibraryOptions, completion: @escaping (_ result: [NSDictionary], _ chunkNum: Int, _ isLastChunk: Bool) -> Void) {

        if(options.includeCloudData == false) {
            if #available(iOS 9.0, *) {
                // remove iCloud source type
                fetchOptions.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
            }
        }

        // let fetchResult = PHAsset.fetchAssets(with: .image, options: self.fetchOptions)
        if(options.includeImages == true && options.includeVideos == true) {
            fetchOptions.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d",
                                                 PHAssetMediaType.image.rawValue,
                                                 PHAssetMediaType.video.rawValue)
        }
        else {
            if(options.includeImages == true) {
                fetchOptions.predicate = NSPredicate(format: "mediaType == %d",
                                                     PHAssetMediaType.image.rawValue)
            }
            else if(options.includeVideos == true) {
                fetchOptions.predicate = NSPredicate(format: "mediaType == %d",
                                                     PHAssetMediaType.video.rawValue)
            }
        }

        let fetchResult = PHAsset.fetchAssets(with: fetchOptions)



	// TODO: do not restart caching on multiple calls
//        if fetchResult.count > 0 {
//
//            var assets = [PHAsset]()
//            fetchResult.enumerateObjects({(asset, index, stop) in
//                assets.append(asset)
//            })
//
//            self.stopCaching()
//            self.cachingImageManager.startCachingImages(for: assets, targetSize: CGSize(width: options.thumbnailWidth, height: options.thumbnailHeight), contentMode: self.contentMode, options: self.imageRequestOptions)
//            self.cacheActive = true
//        }

        var chunk = [NSDictionary]()
        var chunkStartTime = NSDate()
        var chunkNum = 0

        fetchResult.enumerateObjects({ (asset: PHAsset, index, stop) in

            if (options.maxItems > 0 && index + 1 > options.maxItems) {
                completion(chunk, chunkNum, true)
                return
            }

            let libraryItem = self.assetToLibraryItem(asset: asset, useOriginalFileNames: options.useOriginalFileNames, includeAlbumData: options.includeAlbumData)

            chunk.append(libraryItem)

            self.getCompleteInfo(libraryItem, completion: { (fullPath) in

                libraryItem["filePath"] = fullPath

                if index == fetchResult.count - 1 { // Last item
                    completion(chunk, chunkNum, true)
                } else if (options.itemsInChunk > 0 && chunk.count == options.itemsInChunk) ||
                    (options.chunkTimeSec > 0 && abs(chunkStartTime.timeIntervalSinceNow) >= options.chunkTimeSec) {
                    completion(chunk, chunkNum, false)
                    chunkNum += 1
                    chunk = [NSDictionary]()
                    chunkStartTime = NSDate()
                }
            })
        })
    }



    func mimeTypeForPath(path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return mimeTypes[ext] ?? "application/octet-stream"
    }


    func getCompleteInfo(_ libraryItem: NSDictionary, completion: @escaping (_ fullPath: String?) -> Void) {


        let ident = libraryItem.object(forKey: "id") as! String
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [ident], options: self.fetchOptions)
        if fetchResult.count == 0 {
            completion(nil)
            return
        }

        let mime_type = libraryItem.object(forKey: "mimeType") as! String
        let mediaType = mime_type.components(separatedBy: "/").first


        fetchResult.enumerateObjects({
            (obj: AnyObject, idx: Int, stop: UnsafeMutablePointer<ObjCBool>) -> Void in
            let asset = obj as! PHAsset

            if(mediaType == "image") {
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true

                self.requestImageData(asset: asset, options: options) { data in
                    guard let data = data else {
                        completion(nil)
                        return
                    }

                    let tmpURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)

                    try? data.write(to: tmpURL)
                    completion(tmpURL.path)
                }
            }
            else if(mediaType == "video") {

                PHImageManager.default().requestAVAsset(forVideo: asset, options: nil, resultHandler: { (avAsset: AVAsset?, avAudioMix: AVAudioMix?, info: [AnyHashable : Any]?) in

                    if( avAsset is AVURLAsset ) {
                        let video_asset = avAsset as! AVURLAsset
                        let url = URL(fileURLWithPath: video_asset.url.relativePath)
                        completion(url.relativePath)
                    }
                    else if(avAsset is AVComposition) {
                        let token = info?["PHImageFileSandboxExtensionTokenKey"] as! String
                        let path = token.components(separatedBy: ";").last
                        completion(path)
                    }
                })
            }
            else if(mediaType == "audio") {
                // TODO:
                completion(nil)
            }
            else {
                completion(nil) // unknown
            }
        })
    }


    private func assetToLibraryItem(asset: PHAsset, useOriginalFileNames: Bool, includeAlbumData: Bool) -> NSMutableDictionary {
        let libraryItem = NSMutableDictionary()

        libraryItem["id"] = asset.localIdentifier
        libraryItem["fileName"] = useOriginalFileNames ? asset.originalFileName : asset.fileName // originalFilename is much slower
        libraryItem["width"] = asset.pixelWidth
        libraryItem["height"] = asset.pixelHeight

        if let fname = libraryItem["fileName"] as? String {
            libraryItem["mimeType"] = mimeTypeForPath(path: fname)
        } else {
            libraryItem["mimeType"] = "application/octet-stream"
        }


        if let date = asset.creationDate {
            libraryItem["creationDate"] = self.dateFormatter.string(from: date)
        }
        if let location = asset.location {
            libraryItem["latitude"] = location.coordinate.latitude
            libraryItem["longitude"] = location.coordinate.longitude
        }


        if includeAlbumData {
            // This is pretty slow, use only when needed
            var assetCollectionIds = [String]()
            for assetCollectionType in self.assetCollectionTypes {
                let albumsOfAsset = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: assetCollectionType, options: nil)
                albumsOfAsset.enumerateObjects({ (assetCollection: PHAssetCollection, index, stop) in
                    assetCollectionIds.append(assetCollection.localIdentifier)
                })
            }
            libraryItem["albumIds"] = assetCollectionIds
        }

        return libraryItem
    }

    func getAlbums() -> [NSDictionary] {

        var result = [NSDictionary]()

        for assetCollectionType in assetCollectionTypes {

            let fetchResult = PHAssetCollection.fetchAssetCollections(with: assetCollectionType, subtype: .any, options: nil)

            fetchResult.enumerateObjects({ (assetCollection: PHAssetCollection, index, stop) in

                let albumItem = NSMutableDictionary()

                albumItem["id"] = assetCollection.localIdentifier
                albumItem["title"] = assetCollection.localizedTitle

                result.append(albumItem)

            });

        }

        return result;

    }

    func getThumbnail(_ photoId: String, thumbnailWidth: Int, thumbnailHeight: Int, quality: Float, completion: @escaping (_ result: PictureData?) -> Void) {

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [photoId], options: self.fetchOptions)

        if fetchResult.count == 0 {
            completion(nil)
            return
        }

        fetchResult.enumerateObjects({
            (obj: AnyObject, idx: Int, stop: UnsafeMutablePointer<ObjCBool>) -> Void in

            let asset = obj as! PHAsset

            self.cachingImageManager.requestImage(for: asset, targetSize: CGSize(width: thumbnailWidth, height: thumbnailHeight), contentMode: self.contentMode, options: self.thumbnailRequestOptions) {
                (image: UIImage?, imageInfo: [AnyHashable: Any]?) in

                guard let image = image else {
                    completion(nil)
                    return
                }

                let imageData = PhotoLibraryService.image2PictureData(image, quality: quality)

                completion(imageData)
            }
        })

    }

    func getPhoto(_ photoId: String, completion: @escaping (_ result: PictureData?) -> Void) {

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [photoId], options: self.fetchOptions)

        if fetchResult.count == 0 {
            completion(nil)
            return
        }

        fetchResult.enumerateObjects({
            (obj: AnyObject, idx: Int, stop: UnsafeMutablePointer<ObjCBool>) -> Void in

            let asset = obj as! PHAsset

            self.requestImageData(asset: asset, options: self.imageRequestOptions) { data in
            guard let data = data, let image = UIImage(data: data) else {
                completion(nil)
                return
            }

            completion(PhotoLibraryService.image2PictureData(image, quality: 1.0))
        }
        })
    }


    func getLibraryItem(_ itemId: String, mimeType: String, completion: @escaping (_ base64: String?) -> Void) {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [itemId], options: self.fetchOptions)
        if fetchResult.count == 0 {
            completion(nil)
            return
        }

        // TODO: data should be returned as chunks, even for pics.
        // a massive data object might increase RAM usage too much, and iOS will then kill the app.
        fetchResult.enumerateObjects({
            (obj: AnyObject, idx: Int, stop: UnsafeMutablePointer<ObjCBool>) -> Void in
            let asset = obj as! PHAsset

            let mediaType = mimeType.components(separatedBy: "/")[0]

            if(mediaType == "image") {
                self.requestImageData(asset: asset, options: self.imageRequestOptions) { data in
                    guard let data = data else {
                        completion(nil)
                        return
                    }
                    completion(data.base64EncodedString())
                }

            }
            else if(mediaType == "video") {

                PHImageManager.default().requestAVAsset(forVideo: asset, options: nil, resultHandler: { (avAsset: AVAsset?, avAudioMix: AVAudioMix?, info: [AnyHashable : Any]?) in

                    let video_asset = avAsset as! AVURLAsset
                    let url = URL(fileURLWithPath: video_asset.url.relativePath)

                    do {
                        let video_data = try Data(contentsOf: url)
                        let video_base64 = video_data.base64EncodedString()
//                        let mime_type = self.mimeTypes[url.pathExtension.lowercased()]
                        completion(video_base64)
                    }
                    catch _ {
                        completion(nil)
                    }
                })
            }
            else if(mediaType == "audio") {
                // TODO:
                completion(nil)
            }
            else {
                completion(nil) // unknown
            }

        })
    }


    func getVideo(_ videoId: String, completion: @escaping (_ result: PictureData?) -> Void) {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [videoId], options: self.fetchOptions)
        if fetchResult.count == 0 {
            completion(nil)
            return
        }

        fetchResult.enumerateObjects({
            (obj: AnyObject, idx: Int, stop: UnsafeMutablePointer<ObjCBool>) -> Void in

            let asset = obj as! PHAsset


            PHImageManager.default().requestAVAsset(forVideo: asset, options: nil, resultHandler: { (avAsset: AVAsset?, avAudioMix: AVAudioMix?, info: [AnyHashable : Any]?) in

                let video_asset = avAsset as! AVURLAsset
                let url = URL(fileURLWithPath: video_asset.url.relativePath)

                do {
                    let video_data = try Data(contentsOf: url)
                    let pic_data = PictureData(data: video_data, mimeType: "video/quicktime") // TODO: get mime from info dic ?
                    completion(pic_data)
                }
                catch _ {
                    completion(nil)
                }
            })
        })
    }


    func stopCaching() {

        if self.cacheActive {
            self.cachingImageManager.stopCachingImagesForAllAssets()
            self.cacheActive = false
        }

    }

    func requestAuthorization(
        _ success: @escaping () -> Void,
        failure: @escaping (_ err: String) -> Void
    ) {
        if #available(iOS 14.0, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

            if status == .authorized || status == .limited {
                success()
                return
            }

            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        success()
                    } else {
                        failure("requestAuthorization denied by user")
                    }
                }
            }
        } else {
            let status = PHPhotoLibrary.authorizationStatus()

            if status == .authorized {
                success()
                return
            }

            PHPhotoLibrary.requestAuthorization { newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized {
                        success()
                    } else {
                        failure("requestAuthorization denied by user")
                    }
                }
            }
        }
    }

    // as described here: http://stackoverflow.com/questions/11972185/ios-save-photo-in-an-app-specific-album
    // but first find a way to save animated gif with it.
    // TODO: should return library item
    func saveImage(
        _ url: String,
        album: String,
        completion: @escaping (_ libraryItem: NSDictionary?, _ error: String?) -> Void
    ) {
        let imageData: Data
        do {
            imageData = try getDataFromURL(url)
        } catch {
            completion(nil, error.localizedDescription)
            return
        }

        PHPhotoLibrary.shared().performChanges({

            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(
                with: .photo,
                data: imageData,
                options: nil
            )

            let placeholder = creationRequest.placeholderForCreatedAsset

            if let albumCollection = PhotoLibraryService.getOrCreateAlbum(album),
            let placeholder = placeholder {
                let albumChangeRequest =
                    PHAssetCollectionChangeRequest(for: albumCollection)
                albumChangeRequest?.addAssets([placeholder] as NSArray)
            }

        }) { success, error in
            if success {
                completion(nil, nil)   // optionally fetch asset later
            } else {
                completion(nil, error?.localizedDescription)
            }
        }
    }


    func saveVideo(
        _ url: String,
        album: String,
        completion: @escaping (_ libraryItem: NSDictionary?, _ error: String?) -> Void
    ) {
        guard let videoURL = URL(string: url) else {
            completion(nil, "Invalid video URL")
            return
        }

        PHPhotoLibrary.shared().performChanges({

            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(
                with: .video,
                fileURL: videoURL,
                options: nil
            )

            let placeholder = creationRequest.placeholderForCreatedAsset

            if let albumCollection = PhotoLibraryService.getOrCreateAlbum(album),
            let placeholder = placeholder {
                let albumChangeRequest =
                    PHAssetCollectionChangeRequest(for: albumCollection)
                albumChangeRequest?.addAssets([placeholder] as NSArray)
            }

        }) { success, error in
            if success {
                completion(nil, nil)
            } else {
                completion(nil, error?.localizedDescription)
            }
        }
    }

    fileprivate static func getOrCreateAlbum(_ name: String) -> PHAssetCollection? {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", name)

        let fetchResult = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: fetchOptions
        )

        if let existing = fetchResult.firstObject {
            return existing
        }

        var placeholder: PHObjectPlaceholder?

        try? PHPhotoLibrary.shared().performChangesAndWait {
            let request =
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                    withTitle: name
                )
            placeholder = request.placeholderForCreatedAssetCollection
        }

        guard let id = placeholder?.localIdentifier else {
            return nil
        }

        return PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [id],
            options: nil
        ).firstObject
    }



    struct PictureData {
        var data: Data
        var mimeType: String
    }

    // TODO: currently seems useless
    enum PhotoLibraryError: Error, CustomStringConvertible {
        case error(description: String)

        var description: String {
            switch self {
            case .error(let description): return description
            }
        }
    }

    fileprivate func getDataFromURL(_ url: String) throws -> Data {
        if url.hasPrefix("data:") {

            guard let match = self.dataURLPattern.firstMatch(in: url, options: NSRegularExpression.MatchingOptions(rawValue: 0), range: NSMakeRange(0, url.count)) else { // TODO: firstMatchInString seems to be slow for unknown reason
                throw PhotoLibraryError.error(description: "The dataURL could not be parsed")
            }
            let dataPos = match.range(at: 0).length
            let base64 = (url as NSString).substring(from: dataPos)
            guard let decoded = Data(base64Encoded: base64, options: NSData.Base64DecodingOptions(rawValue: 0)) else {
                throw PhotoLibraryError.error(description: "The dataURL could not be decoded")
            }

            return decoded

        } else {

            guard let nsURL = URL(string: url) else {
                throw PhotoLibraryError.error(description: "The url could not be decoded: \(url)")
            }
            guard let fileContent = try? Data(contentsOf: nsURL) else {
                throw PhotoLibraryError.error(description: "The url could not be read: \(url)")
            }

            return fileContent

        }
    }

    fileprivate static func image2PictureData(
        _ image: UIImage,
        quality: Float
    ) -> PictureData? {

        let data: Data?
        let mimeType: String

        if imageHasAlpha(image) {
            data = UIImagePNGRepresentation(image)
            mimeType = "image/png"
        } else {
            data = UIImageJPEGRepresentation(image, CGFloat(quality))
            mimeType = "image/jpeg"
        }

        guard let d = data else {
            return nil
        }

        return PictureData(data: d, mimeType: mimeType)
    }

    fileprivate static func imageHasAlpha(_ image: UIImage) -> Bool {
        let alphaInfo = (image.cgImage)?.alphaInfo
        return alphaInfo == .first || alphaInfo == .last || alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast
    }

    private func requestImageData(
        asset: PHAsset,
        options: PHImageRequestOptions,
        completion: @escaping (Data?) -> Void
    ) {
        if #available(iOS 13.0, *) {
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, _ in
                completion(data)
            }
        } else {
            PHImageManager.default().requestImageData(
                for: asset,
                options: options
            ) { data, _, _, _ in
                completion(data)
            }
        }
    }



}