/* This Source Code Form is subject to the terms of the Mozilla Public
* License, v. 2.0. If a copy of the MPL was not distributed with this
* file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit

import SnapKit
import Storage

private struct NavigatorPanelUX {
    static let BackgroundColor = UIConstants.PanelBackgroundColor
    // DefaultURL of NavigatorPanel
    static let NavigatorPanelURL = "http://mobile.firefoxchina.cn/index.html"
    static let NavigatorPanelURLBackup = "http://mobile.firefoxchina.cn/index2.html"
    // Local file of html
    static let NavigatorResourceName = "zh_CNNavigatorURL"
    static let NavigatorResourceURL = NSURL(fileURLWithPath: NSBundle.mainBundle().pathForResource(NavigatorPanelUX.NavigatorResourceName,ofType: "html")!)
}

class NavigatorPanel: UIViewController, UIWebViewDelegate, HomePanel {
    weak var homePanelDelegate: HomePanelDelegate? = nil
    var profile: Profile? {
        didSet {
            // If necessary
        }
    }
    private var webView: UIWebView!

    override func viewDidLoad() {
        super.viewDidLoad()

        webView = UIWebView()
        webView.delegate = self
        view.backgroundColor = NavigatorPanelUX.BackgroundColor
        view.addSubview(webView)
        reloadData()
    }

    override func viewWillLayoutSubviews() {
        webView.snp_makeConstraints { make in
            make.top.left.right.bottom.equalTo(self.view)
        }
    }

    private func reloadData() {
        let url = NSURL(string: NavigatorPanelUX.NavigatorPanelURL )
        let request = NSURLRequest(URL: url!, cachePolicy: .UseProtocolCachePolicy, timeoutInterval: 10)
        webView.loadRequest(request)
    }

    // LoadData from local html
    private func webViewLoadLocal(webView: UIWebView) {
        let url = NavigatorPanelUX.NavigatorResourceURL
        let request = NSURLRequest(URL: url)
        print("LoadData from local html")
        webView.loadRequest(request)
    }

    func webView(webView: UIWebView, didFailLoadWithError error: NSError?) {
        webViewLoadLocal(webView)
    }

    func webView(webView: UIWebView, shouldStartLoadWithRequest request: NSURLRequest, navigationType: UIWebViewNavigationType) -> Bool {
        if request.URL!.absoluteString == NavigatorPanelUX.NavigatorPanelURL || request.URL! == NavigatorPanelUX.NavigatorResourceURL {
            // Set up in NavigatorPanel
            print("Set up in NavigatorPanel")
            print(request.URL?.absoluteString)
            return true
        }
        // Set up in BrowserWebView
        homePanelDelegate?.homePanel(self, didSelectURL: request.URL!, visitType: VisitType.Bookmark)
        print("Set up in BrowserWebView")
        print(request.URL?.absoluteString)
        return false
    }
}