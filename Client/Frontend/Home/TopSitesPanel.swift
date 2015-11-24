/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import Shared
import XCGLogger
import Storage

private let log = Logger.browserLogger

private let ThumbnailIdentifier = "Thumbnail"

extension CGSize {
    public func widthLargerOrEqualThanHalfIPad() -> Bool {
        let halfIPadSize: CGFloat = 507
        return width >= halfIPadSize
    }
}

class TopSitesPanel: UIViewController {
    weak var homePanelDelegate: HomePanelDelegate?

    private var collection: TopSitesCollectionView? = nil
    private lazy var dataSource: TopSitesDataSource = {
        return TopSitesDataSource(profile: self.profile)
    }()
    private lazy var layout: TopSitesLayout = { return TopSitesLayout() }()

    private lazy var maxFrecencyLimit: Int = {
        return max(
            self.calculateApproxThumbnailCountForOrientation(UIInterfaceOrientation.LandscapeLeft),
            self.calculateApproxThumbnailCountForOrientation(UIInterfaceOrientation.Portrait)
        )
    }()

    private var cachedCursor: Cursor<Site>?
    private let deleteTopSitesQueue: dispatch_queue_t = dispatch_queue_create("org.mozilla.ios.DeleteTopSitesQueue", nil)

    var editingThumbnails: Bool = false {
        didSet {
            if editingThumbnails != oldValue {
                dataSource.editingThumbnails = editingThumbnails

                if editingThumbnails {
                    homePanelDelegate?.homePanelWillEnterEditingMode?(self)
                }

                updateAllRemoveButtonStates()
            }
        }
    }

    let profile: Profile

    override func viewWillTransitionToSize(size: CGSize, withTransitionCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransitionToSize(size, withTransitionCoordinator: coordinator)

        coordinator.animateAlongsideTransition({ context in
            self.dataSource.setDataFromCursor(self.cachedCursor, usingLayout: self.layout)
            self.collection?.reloadData()
        }, completion: nil)
    }

    override func supportedInterfaceOrientations() -> UIInterfaceOrientationMask {
        return UIInterfaceOrientationMask.AllButUpsideDown
    }

    init(profile: Profile) {
        self.profile = profile
        super.init(nibName: nil, bundle: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "notificationReceived:", name: NotificationFirefoxAccountChanged, object: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "notificationReceived:", name: ProfileDidFinishSyncingNotification, object: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "notificationReceived:", name: NotificationPrivateDataClearedHistory, object: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let collection = TopSitesCollectionView(frame: self.view.frame, collectionViewLayout: layout)
        collection.backgroundColor = UIConstants.PanelBackgroundColor
        collection.delegate = self
        collection.dataSource = dataSource
        collection.registerClass(ThumbnailCell.self, forCellWithReuseIdentifier: ThumbnailIdentifier)
        collection.keyboardDismissMode = .OnDrag
        view.addSubview(collection)
        collection.snp_makeConstraints { make in
            make.edges.equalTo(self.view)
        }
        self.collection = collection

        self.profile.history.setTopSitesCacheSize(Int32(maxFrecencyLimit))
        self.refreshTopSites(maxFrecencyLimit)
    }

    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self, name: NotificationFirefoxAccountChanged, object: nil)
        NSNotificationCenter.defaultCenter().removeObserver(self, name: ProfileDidFinishSyncingNotification, object: nil)
        NSNotificationCenter.defaultCenter().removeObserver(self, name: NotificationPrivateDataClearedHistory, object: nil)
    }
    
    func notificationReceived(notification: NSNotification) {
        switch notification.name {
        case NotificationFirefoxAccountChanged, ProfileDidFinishSyncingNotification, NotificationPrivateDataClearedHistory:
            refreshTopSites(maxFrecencyLimit)
            break
        default:
            // no need to do anything at all
            log.warning("Received unexpected notification \(notification.name)")
            break
        }
    }

    private func updateAllRemoveButtonStates() {
        collection?.indexPathsForVisibleItems().forEach { indexPath in
            updateRemoveButtonStateForIndexPath(indexPath)
        }
    }

    private func updateRemoveButtonStateForIndexPath(indexPath: NSIndexPath, forCell cell: ThumbnailCell? = nil) {
        // If we have a cell passed in, use it. If not, then use the indexPath to get it.
        let cell = cell ?? (collection?.cellForItemAtIndexPath(indexPath) as? ThumbnailCell)

        dataSource[indexPath.row] is SuggestedSite ?
            cell?.toggleRemoveButton(false) :
            cell?.toggleRemoveButton(editingThumbnails)
    }

    private func refreshTopSites(frecencyLimit: Int) {
        // Reload right away with whatever is in the cache, then check to see if the cache is invalid. If it's invalid,
        // invalidate the cache and requery. This allows us to always show results right away if they are cached but
        // also load in the up-to-date results asynchronously if needed
        reloadTopSitesWithLimit(frecencyLimit) >>> {
            return self.profile.history.updateTopSitesCacheIfInvalidated() >>== { result in
                return result ? self.reloadTopSitesWithLimit(frecencyLimit) : succeed()
            }
        }
    }

    private func reloadTopSitesWithLimit(limit: Int) -> Success {
        return invalidateTopSitesCursor().bindQueue(dispatch_get_main_queue()) { _ in
            self.dataSource.setDataFromCursor(self.cachedCursor, usingLayout: self.layout)
            self.dataSource.profile = self.profile

            // redraw now that we've updated our sources
            self.collection?.collectionViewLayout.invalidateLayout()
            self.collection?.setNeedsLayout()
            self.collection?.reloadData()
            return succeed()
        }
    }

    private func invalidateTopSitesCursor() -> Success {
        return profile.history.getTopSitesWithLimit(maxFrecencyLimit).bind { result in
            self.cachedCursor = result.successValue
            return succeed()
        }
    }

    /**
    Calculates an approximation of the number of tiles we want to display for the given orientation. This
    method uses the screen's size as it's basis for the calculation instead of the collectionView's since the 
    collectionView's bounds is determined until the next layout pass.

    - parameter orientation: Orientation to calculate number of tiles for

    - returns: Rough tile count we will be displaying for the passed in orientation
    */
    private func calculateApproxThumbnailCountForOrientation(orientation: UIInterfaceOrientation) -> Int {
        let size = UIScreen.mainScreen().bounds.size
        let portraitSize = CGSize(width: min(size.width, size.height), height: max(size.width, size.height))

        func calculateRowsForSize(size: CGSize, columns: Int) -> Int {
            let insets = ThumbnailCellUX.insetsForCollectionViewSize(size,
                traitCollection:  traitCollection)
            let thumbnailWidth = (size.width - insets.left - insets.right) / CGFloat(columns)
            let thumbnailHeight = thumbnailWidth / CGFloat(ThumbnailCellUX.ImageAspectRatio)
            return max(2, Int(size.height / thumbnailHeight))
        }

        let numberOfColumns: Int
        let numberOfRows: Int

        if UIInterfaceOrientationIsLandscape(orientation) {
            numberOfColumns = 5
            numberOfRows = calculateRowsForSize(CGSize(width: portraitSize.height, height: portraitSize.width), columns: numberOfColumns)
        } else {
            numberOfColumns = 4
            numberOfRows = calculateRowsForSize(portraitSize, columns: numberOfColumns)
        }

        return numberOfColumns * numberOfRows
    }
}

extension TopSitesPanel: HomePanel {
    func endEditing() {
        editingThumbnails = false
    }
}

extension TopSitesPanel: UICollectionViewDelegate {
    func collectionView(collectionView: UICollectionView, didSelectItemAtIndexPath indexPath: NSIndexPath) {
        if editingThumbnails {
            return
        }

        if let site = dataSource[indexPath.item] {
            // We're gonna call Top Sites bookmarks for now.
            let visitType = VisitType.Bookmark
            let destination = NSURL(string: site.url)?.domainURL() ?? NSURL(string: "about:blank")!
            homePanelDelegate?.homePanel(self, didSelectURL: destination, visitType: visitType)
        }
    }

    func collectionView(collectionView: UICollectionView, willDisplayCell cell: UICollectionViewCell, forItemAtIndexPath indexPath: NSIndexPath) {
        let thumbnailCell = cell as? ThumbnailCell
        thumbnailCell?.delegate = self
        updateRemoveButtonStateForIndexPath(indexPath, forCell: thumbnailCell)
    }
}

extension TopSitesPanel: ThumbnailCellDelegate {

    func didRemoveThumbnail(thumbnailCell: ThumbnailCell) {
        guard let indexPath = collection?.indexPathForCell(thumbnailCell),
            let site = dataSource[indexPath.item] else {
            return
        }

        self.removeSiteAtIndexPath(indexPath)
        dispatch_async(deleteTopSitesQueue) {
            self.profile.history.removeSiteFromTopSites(site).value
            self.profile.history.refreshTopSitesCache().value

            guard let site = self.siteToAppend().value else { return }
            dispatch_async(dispatch_get_main_queue()) {
                self.appendSite(site)
            }
        }
    }

    func removeSiteAtIndexPath(indexPath: NSIndexPath) {
        dataSource.removeSiteAtIndex(indexPath.item)
        collection?.deleteItemsAtIndexPaths([indexPath])
    }

    func siteToAppend() -> Deferred<Site?> {
        let deferred = Deferred<Site?>()
        self.invalidateTopSitesCursor().uponQueue(dispatch_get_main_queue()) { _ in
            guard let cursor = self.cachedCursor where cursor.count + SuggestedSites.count > self.layout.thumbnailCount else {
                deferred.fill(nil)
                return
            }

            let i = self.layout.thumbnailCount - 1
            let site: Site?
            if i < cursor.count {
                site = cursor[i]!
            } else if i >= cursor.count && i < SuggestedSites.count + cursor.count {
                site = SuggestedSites[i - cursor.count]!
            } else {
                site = nil
            }
            deferred.fill(site)
        }

        return deferred
    }

    func appendSite(site: Site) {
        dataSource.appendSite(site)

        let insertPosition = dataSource.count - 1
        let indexPath = NSIndexPath(forItem: insertPosition, inSection: 0)
        collection?.insertItemsAtIndexPaths([indexPath])
    }

    func didLongPressThumbnail(thumbnailCell: ThumbnailCell) {
        editingThumbnails = true
    }
}

private class TopSitesCollectionView: UICollectionView {
    private override func touchesBegan(touches: Set<UITouch>, withEvent event: UIEvent?) {
        // Hide the keyboard if this view is touched.
        window?.rootViewController?.view.endEditing(true)
        super.touchesBegan(touches, withEvent: event)
    }
}

private class TopSitesLayout: UICollectionViewLayout {

    private var thumbnailRows: Int {
        assert(NSThread.isMainThread(), "Interacts with UIKit components - not thread-safe.")
        return max(2, Int((self.collectionView?.frame.height ?? self.thumbnailHeight) / self.thumbnailHeight))
    }

    private var thumbnailCols: Int {
        assert(NSThread.isMainThread(), "Interacts with UIKit components - not thread-safe.")

        let size = collectionView?.bounds.size ?? CGSizeZero
        let traitCollection = collectionView!.traitCollection
        if traitCollection.horizontalSizeClass == .Compact {
            // Landscape iPHone
            if traitCollection.verticalSizeClass == .Compact {
                return 5
            }
            // Split screen iPad width
            else if size.widthLargerOrEqualThanHalfIPad() ?? false {
                return 4
            }
            // iPhone portrait
            else {
                return 3
            }
        } else {
            // Portrait iPad
            if size.height > size.width {
                return 4;
            }
            // Landscape iPad
            else {
                return 5;
            }
        }
    }

    private var thumbnailCount: Int {
        assert(NSThread.isMainThread(), "Interacts with UIKit components - not thread-safe.")
        return thumbnailRows * thumbnailCols
    }

    private var width: CGFloat {
        assert(NSThread.isMainThread(), "Interacts with UIKit components - not thread-safe.")
        return self.collectionView?.frame.width ?? 0
    }

    // The width and height of the thumbnail here are the width and height of the tile itself, not the image inside the tile.
    private var thumbnailWidth: CGFloat {
        assert(NSThread.isMainThread(), "Interacts with UIKit components - not thread-safe.")

        let size = collectionView?.bounds.size ?? CGSizeZero
        let insets = ThumbnailCellUX.insetsForCollectionViewSize(size,
            traitCollection:  collectionView!.traitCollection)

        return floor(width - insets.left - insets.right) / CGFloat(thumbnailCols)
    }
    // The tile's height is determined the aspect ratio of the thumbnails width. We also take into account
    // some padding between the title and the image.
    private var thumbnailHeight: CGFloat {
        assert(NSThread.isMainThread(), "Interacts with UIKit components - not thread-safe.")

        return floor(thumbnailWidth / CGFloat(ThumbnailCellUX.ImageAspectRatio))
    }

    // Used to calculate the height of the list.
    private var count: Int {
        if let dataSource = self.collectionView?.dataSource as? TopSitesDataSource {
            return dataSource.collectionView(self.collectionView!, numberOfItemsInSection: 0)
        }
        return 0
    }

    private var topSectionHeight: CGFloat {
        let maxRows = ceil(Float(count) / Float(thumbnailCols))
        let rows = min(Int(maxRows), thumbnailRows)
        let size = collectionView?.bounds.size ?? CGSizeZero
        let insets = ThumbnailCellUX.insetsForCollectionViewSize(size,
            traitCollection:  collectionView!.traitCollection)
        return thumbnailHeight * CGFloat(rows) + insets.top + insets.bottom
    }

    private func getIndexAtPosition(y: CGFloat) -> Int {
        if y < topSectionHeight {
            let row = Int(y / thumbnailHeight)
            return min(count - 1, max(0, row * thumbnailCols))
        }
        return min(count - 1, max(0, Int((y - topSectionHeight) / UIConstants.DefaultRowHeight + CGFloat(thumbnailCount))))
    }

    override func collectionViewContentSize() -> CGSize {
        if count <= thumbnailCount {
            return CGSize(width: width, height: topSectionHeight)
        }

        let bottomSectionHeight = CGFloat(count - thumbnailCount) * UIConstants.DefaultRowHeight
        return CGSize(width: width, height: topSectionHeight + bottomSectionHeight)
    }

    private var layoutAttributes:[UICollectionViewLayoutAttributes]?

    private override func prepareLayout() {
        var layoutAttributes = [UICollectionViewLayoutAttributes]()
        for section in 0..<(self.collectionView?.numberOfSections() ?? 0) {
            for item in 0..<(self.collectionView?.numberOfItemsInSection(section) ?? 0) {
                let indexPath = NSIndexPath(forItem: item, inSection: section)
                guard let attrs = self.layoutAttributesForItemAtIndexPath(indexPath) else { continue }
                layoutAttributes.append(attrs)
            }
        }
        self.layoutAttributes = layoutAttributes
    }

    override func layoutAttributesForElementsInRect(rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var attrs = [UICollectionViewLayoutAttributes]()
        if let layoutAttributes = self.layoutAttributes {
            for attr in layoutAttributes {
                if CGRectIntersectsRect(rect, attr.frame) {
                    attrs.append(attr)
                }
            }
        }

        return attrs
    }

    override func layoutAttributesForItemAtIndexPath(indexPath: NSIndexPath) -> UICollectionViewLayoutAttributes? {
        let attr = UICollectionViewLayoutAttributes(forCellWithIndexPath: indexPath)

        // Set the top thumbnail frames.
        let row = floor(Double(indexPath.item / thumbnailCols))
        let col = indexPath.item % thumbnailCols
        let size = collectionView?.bounds.size ?? CGSizeZero
        let insets = ThumbnailCellUX.insetsForCollectionViewSize(size,
            traitCollection:  collectionView!.traitCollection)
        let x = insets.left + thumbnailWidth * CGFloat(col)
        let y = insets.top + CGFloat(row) * thumbnailHeight
        attr.frame = CGRectMake(ceil(x), ceil(y), thumbnailWidth, thumbnailHeight)

        return attr
    }
}

private class TopSitesDataSource: NSObject, UICollectionViewDataSource {
    var count: Int {
        return data.count
    }

    var profile: Profile
    var editingThumbnails: Bool = false

    private var data: [Site] = []

    private let blurQueue = dispatch_queue_create("FaviconBlurQueue", DISPATCH_QUEUE_CONCURRENT)
    private let BackgroundFadeInDuration: NSTimeInterval = 0.3

    init(profile: Profile) {
        self.profile = profile
    }

    func setDataFromCursor(cursor: Cursor<Site>?, usingLayout layout: TopSitesLayout) {
        guard let cursor = cursor else {
            data = []
            return
        }

        let limit = min(layout.thumbnailCount, cursor.count + SuggestedSites.count)
        let combinedData = cursor.asArray() + (SuggestedSites.asArray() as [Site])
        let dataSlice = combinedData[0..<limit]
        data = Array(dataSlice)
    }

    func removeSiteAtIndex(index: Int) {
        guard index >= 0 && index < data.count else {
            return
        }
        let site = data.removeAtIndex(index)
        print("removed site named: \(site.title)")
    }

    func appendSite(site: Site) {
        data.append(site)
        print("added site named: \(site.title)")
    }

    @objc func collectionView(collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return data.count
    }

    private func setDefaultThumbnailBackgroundForCell(cell: ThumbnailCell) {
        cell.imageView.image = UIImage(named: "defaultTopSiteIcon")!
        cell.imageView.contentMode = UIViewContentMode.Center
    }

    private func setBlurredBackground(image: UIImage, withURL url: NSURL, forCell cell: ThumbnailCell) {
        let blurredKey = "\(url.absoluteString)!blurred"
        if let blurredImage = SDImageCache.sharedImageCache().imageFromMemoryCacheForKey(blurredKey) {
            cell.backgroundImage.image = blurredImage
        } else {
            let blurredImage = image.applyLightEffect()
            SDImageCache.sharedImageCache().storeImage(blurredImage, forKey: blurredKey, toDisk: false)
            cell.backgroundImage.alpha = 0
            cell.backgroundImage.image = blurredImage
            UIView.animateWithDuration(self.BackgroundFadeInDuration) {
                cell.backgroundImage.alpha = 1
            }
        }
    }

    private func getFaviconForCell(cell:ThumbnailCell, site: Site, profile: Profile) {
        setDefaultThumbnailBackgroundForCell(cell)
        guard let url = site.url.asURL else { return }

        FaviconFetcher.getForURL(url, profile: profile) >>== { icons in
            if icons.count == 0 { return }
            guard let url = icons[0].url.asURL else { return }

            cell.imageView.sd_setImageWithURL(url) { (img, err, type, url) -> Void in
                guard let img = img else {
                    let icon = Favicon(url: "", date: NSDate(), type: IconType.NoneFound)
                    profile.favicons.addFavicon(icon, forSite: site)
                    self.setDefaultThumbnailBackgroundForCell(cell)
                    return
                }

                cell.image = img
                self.setBlurredBackground(img, withURL: url, forCell: cell)
            }
        }
    }

    private func configureCell(cell: ThumbnailCell, forSite site: Site, isEditing editing: Bool, profile: Profile) {

        // We always want to show the domain URL, not the title.
        //
        // Eventually we can do something more sophisticated — e.g., if the site only consists of one
        // history item, show it, and otherwise use the longest common sub-URL (and take its title
        // if you visited that exact URL), etc. etc. — but not yet.
        //
        // The obvious solution here and in collectionView:didSelectItemAtIndexPath: is for the cursor
        // to return domain sites, not history sites -- that is, with the right icon, title, and URL --
        // and for this code to just use what it gets.
        //
        // Instead we'll painstakingly re-extract those things here.

        let domainURL = NSURL(string: site.url)?.normalizedHost() ?? site.url
        cell.textLabel.text = domainURL
        cell.accessibilityLabel = cell.textLabel.text
        cell.removeButton.hidden = !editing

        guard let icon = site.icon else {
            getFaviconForCell(cell, site: site, profile: profile)
            return
        }

        // We've looked before recently and didn't find a favicon
        switch icon.type {
        case .NoneFound where NSDate().timeIntervalSinceDate(icon.date) < FaviconFetcher.ExpirationTime:
            self.setDefaultThumbnailBackgroundForCell(cell)
        default:
            cell.imageView.sd_setImageWithURL(icon.url.asURL, completed: { (img, err, type, url) -> Void in
                if let img = img {
                    cell.image = img
                    self.setBlurredBackground(img, withURL: url, forCell: cell)
                } else {
                    self.getFaviconForCell(cell, site: site, profile: profile)
                }
            })
        }
    }

    private func configureCell(cell: ThumbnailCell, forSuggestedSite site: SuggestedSite) {
        cell.textLabel.text = site.title.isEmpty ? NSURL(string: site.url)?.normalizedHostAndPath() : site.title
        cell.imageWrapper.backgroundColor = site.backgroundColor
        cell.imageView.contentMode = UIViewContentMode.ScaleAspectFit
        cell.accessibilityLabel = cell.textLabel.text

        guard let icon = site.wordmark.url.asURL,
            let host = icon.host else {
                self.setDefaultThumbnailBackgroundForCell(cell)
                return
        }

        if icon.scheme == "asset" {
            cell.imageView.image = UIImage(named: host)
        } else {
            cell.imageView.sd_setImageWithURL(icon, completed: { img, err, type, key in
                if img == nil {
                    self.setDefaultThumbnailBackgroundForCell(cell)
                }
            })
        }
    }

    subscript(index: Int) -> Site? {
        // Bounds check on provided index
        guard (index < data.count + SuggestedSites.count) && index >= 0 else {
            return nil
        }

        if index >= data.count && index < data.count + SuggestedSites.count {
            return SuggestedSites[index - data.count]
        } else {
            return data[index] as Site?
        }
    }

    @objc func collectionView(collectionView: UICollectionView, cellForItemAtIndexPath indexPath: NSIndexPath) -> UICollectionViewCell {
        // Cells for the top site thumbnails.
        let site = self[indexPath.item]!
        let cell = collectionView.dequeueReusableCellWithReuseIdentifier(ThumbnailIdentifier, forIndexPath: indexPath) as! ThumbnailCell

        let traitCollection = collectionView.traitCollection
        cell.updateLayoutForCollectionViewSize(collectionView.bounds.size, traitCollection: traitCollection)

        if let suggestedSite = data[indexPath.item] as? SuggestedSite {
            configureCell(cell, forSuggestedSite: suggestedSite)
        } else {
            configureCell(cell, forSite: site, isEditing: editingThumbnails, profile: profile)
        }

        return cell
    }
}
