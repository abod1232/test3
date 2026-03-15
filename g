 @SuppressLint("SetJavaScriptEnabled")
    private suspend fun resolveWithWebView(
        iframeUrl: String,
        referer: String
    ): String? = suspendCancellableCoroutine { cont ->

        val activity = context as? Activity
        if (activity == null || activity.isFinishing) {
            cont.resume(null)
            return@suspendCancellableCoroutine
        }

        activity.runOnUiThread {
            // === Headless / invisible Dialog + WebView setup ===
            val dialog = Dialog(activity)
            dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)
            dialog.setCancelable(false)
            // make dialog fully non-interactive and transparent
            dialog.window?.apply {
                setBackgroundDrawableResource(android.R.color.transparent)
                clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
                addFlags(
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                )
            }

            // Create a single-pixel WebView (invisible)
            val webView = WebView(activity).apply {
                layoutParams = ViewGroup.LayoutParams(1, 1)
                visibility = View.INVISIBLE
                isHorizontalScrollBarEnabled = false
                isVerticalScrollBarEnabled = false
            }

            // Put the WebView into the dialog as its content (so it's attached to window)
            try {
                dialog.setContentView(webView, ViewGroup.LayoutParams(1, 1))
                // move the window far off-screen to be extra-safe (some OEMs may still show)
                dialog.window?.attributes = dialog.window?.attributes?.apply {
                    width = 1
                    height = 1
                    x = -10000
                    y = -10000
                    gravity = Gravity.START or Gravity.TOP
                }
                dialog.show()
            } catch (e: Exception) {
                // fallback: attach to activity content view
                try {
                    val decor = activity.window?.decorView as? ViewGroup
                    decor?.addView(webView, FrameLayout.LayoutParams(1, 1, Gravity.START or Gravity.TOP))
                } catch (_: Exception) { }
            }

            // WebView settings
            val settings = webView.settings
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                databaseEnabled = true
                allowContentAccess = true
                allowFileAccess = true
                allowFileAccessFromFileURLs = true
                allowUniversalAccessFromFileURLs = true
                javaScriptCanOpenWindowsAutomatically = true
                mediaPlaybackRequiresUserGesture = false
                loadWithOverviewMode = true
                useWideViewPort = true
                builtInZoomControls = true
                displayZoomControls = false
                setSupportMultipleWindows(true)
                mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
                cacheMode = WebSettings.LOAD_DEFAULT
                userAgentString = lastValidUserAgent
            }

            val cookieManager = CookieManager.getInstance()
            try {
                cookieManager.setAcceptCookie(true)
                cookieManager.setAcceptThirdPartyCookies(webView, true)
                cookieManager.flush()
            } catch (_: Exception) { }

            val client = app.baseClient.newBuilder()
                .followRedirects(true)
                .followSslRedirects(true)
                .cookieJar(okhttp3.CookieJar.NO_COOKIES)
                .build()

            // storage & synchronization
            val foundM3u8 = linkedSetOf<String>()
            var finished = false
            val finishLock = Any()
            val handler = Handler(Looper.getMainLooper())
            var finishRunnable: Runnable? = null
            val overallTimeoutMs = 20_000L

            fun cleanup() {
                try {
                    if (webView.parent is ViewGroup) {
                        (webView.parent as ViewGroup).removeView(webView)
                    }
                } catch (_: Exception) {}
                try { webView.stopLoading() } catch (_: Exception) {}
                try { webView.destroy() } catch (_: Exception) {}
                try { cookieManager.flush() } catch (_: Exception) {}
                try { if (dialog.isShowing) dialog.dismiss() } catch (_: Exception) {}
            }

            fun safeFinish(result: String?) {
                synchronized(finishLock) {
                    if (finished) return
                    finished = true
                }
                try {
                    if (cont.isActive) cont.resume(result)
                } catch (_: Exception) {}
                cleanup()
            }

            fun chooseAndFinish() {
                if (foundM3u8.isEmpty()) {
                    safeFinish(null)
                    return
                }
                // prefer strict .m3u8 path (avoid analytics ping with m3u8 in query)
                val strict = foundM3u8.firstOrNull {
                    val clean = it.substringBefore("?")
                    clean.endsWith(".m3u8") && (clean.contains("master") || clean.contains("playlist") || clean.contains("index"))
                } ?: foundM3u8.firstOrNull { it.substringBefore("?").endsWith(".m3u8") }
                val final = strict ?: foundM3u8.first()
                safeFinish(final)
            }

            handler.postDelayed({
                synchronized(finishLock) {
                    if (!finished) chooseAndFinish()
                }
            }, overallTimeoutMs)

            // Shared WebViewClient (store then assign to avoid getWebViewClient on older APIs)
            lateinit var sharedWebViewClient: WebViewClient
            sharedWebViewClient = object : WebViewClient() {

                override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                    Log.d("FASEL_DEBUG", "Headless Page Started: $url")
                    super.onPageStarted(view, url, favicon)
                }

                override fun onPageFinished(view: WebView?, url: String?) {
                    super.onPageFinished(view, url)
                    try {
                        // inject sniffer + force play + jw read
                        val js = """
                        (function() {
                            try {
                                if (!window.__NET_HOOKED__) {
                                    window.__NET_HOOKED__ = true;
                                    // hook fetch
                                    const _fetch = window.fetch;
                                    if (_fetch) {
                                        window.fetch = function() {
                                            return _fetch.apply(this, arguments).then(function(resp) {
                                                try {
                                                    const u = resp && resp.url ? resp.url : '';
                                                    if (u && u.indexOf('.m3u8') !== -1) {
                                                        console.log('NET_M3U8::' + u);
                                                    }
                                                    try {
                                                        resp.clone().text().then(function(t){
                                                            var m = t && t.match(/https?:\/\/[^"'\\s]+\\.m3u8/);
                                                            if (m) console.log('NET_M3U8::' + m[0]);
                                                        }).catch(function(){});
                                                    } catch(e){}
                                                } catch(e){}
                                                return resp;
                                            });
                                        };
                                    }
                                    // hook XHR
                                    const _open = XMLHttpRequest.prototype.open;
                                    XMLHttpRequest.prototype.open = function(method, u) {
                                        this.addEventListener('load', function() {
                                            try {
                                                if (typeof u === 'string' && u.indexOf('.m3u8') !== -1) {
                                                    console.log('NET_M3U8::' + u);
                                                }
                                                try {
                                                    var txt = this.responseText || '';
                                                    var m = txt && txt.match(/https?:\/\/[^"'\\s]+\\.m3u8/);
                                                    if (m) console.log('NET_M3U8::' + m[0]);
                                                } catch(e){}
                                            } catch(e){}
                                        });
                                        return _open.apply(this, arguments);
                                    };
                                    console.log('🌐 Network sniffer installed');
                                }
                                // force play attempts (jw api + clicks)
                                try {
                                    if (typeof jwplayer === 'function') {
                                        try {
                                            var p = jwplayer();
                                            if (p && typeof p.play === 'function') {
                                                try { p.setMute(true); } catch(e) {}
                                                try { p.play(); console.log('JW_API_PLAY'); } catch(e) {}
                                            }
                                        } catch(e){}
                                    }
                                } catch(e){}
                                var sels = ['.jw-display-icon-container','.jw-icon-play','.jw-svg-icon-play','.jw-display','.jwplayer','#player','.player','video'];
                                for (var i=0;i<sels.length;i++){
                                    try {
                                        var el = document.querySelector(sels[i]);
                                        if (el) { el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true})); console.log('FORCE_CLICK:'+sels[i]); }
                                    } catch(e){}
                                }
                                // read jw playlist
                                try {
                                    if (typeof jwplayer === 'function') {
                                        try {
                                            var p2 = jwplayer();
                                            if (p2 && typeof p2.getPlaylist === 'function') {
                                                var pl = p2.getPlaylist();
                                                if (pl && pl.length>0 && pl[0].sources) {
                                                    pl[0].sources.forEach(function(s){
                                                        try {
                                                            if (s && s.file && s.file.indexOf('.m3u8') !== -1) {
                                                                console.log('JW_M3U8::' + s.file);
                                                            }
                                                        } catch(e){}
                                                    });
                                                }
                                            }
                                        } catch(e){}
                                    }
                                } catch(e){}
                            } catch(err){}
                        })();
                    """.trimIndent()
                        try { view?.evaluateJavascript(js, null) } catch (_: Exception) {}
                    } catch (_: Exception) {}
                }

                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                    val url = request.url.toString()
                    val method = request.method
                    val lower = url.lowercase()

                    // ignore images/fonts/styles
                    if (lower.endsWith(".png") || lower.endsWith(".jpg") || lower.endsWith(".woff2") || lower.endsWith(".css")) {
                        return super.shouldInterceptRequest(view, request)
                    }

                    // only intercept real .m3u8 files (path ends with .m3u8)
                    if (method.equals("GET", ignoreCase = true) &&
                        lower.contains(".m3u8") &&
                        lower.substringBefore("?").endsWith(".m3u8")
                    ) {
                        try {
                            Log.d("FASEL_DEBUG", "Headless M3U8 detected (collecting): $url")
                            synchronized(foundM3u8) {
                                if (!foundM3u8.contains(url)) {
                                    foundM3u8.add(url)
                                    if (lower.contains("master") || lower.contains("playlist") || lower.contains("index.m3u8")) {
                                        finishRunnable?.let { handler.removeCallbacks(it) }
                                        finishRunnable = Runnable { chooseAndFinish() }
                                        handler.postDelayed(finishRunnable!!, 1200)
                                    } else {
                                        if (finishRunnable == null) {
                                            finishRunnable = Runnable { chooseAndFinish() }
                                            handler.postDelayed(finishRunnable!!, 6000)
                                        }
                                    }
                                }
                            }

                            // proxy via OkHttp to pass headers/cookies
                            val reqBuilder = OkRequest.Builder().url(url)
                                .header("User-Agent", lastValidUserAgent)
                                .header("Referer", referer)
                                .header("Origin", mainUrl)
                            try { cookieManager.getCookie(url)?.let { ck -> reqBuilder.header("Cookie", ck) } } catch (_: Exception) {}
                            val response = client.newCall(reqBuilder.build()).execute()
                            if (!response.isSuccessful) {
                                Log.d("FASEL_DEBUG", "Proxy error ${response.code} for $url")
                                return null
                            }
                            response.headers("Set-Cookie").forEach { try { cookieManager.setCookie(url, it) } catch (_: Exception) {} }
                            val contentType = response.header("content-type")?.split(";")?.first() ?: "application/vnd.apple.mpegurl"
                            val encoding = "utf-8"
                            val stream = response.body?.byteStream()
                            return WebResourceResponse(contentType, encoding, stream)
                        } catch (e: Exception) {
                            Log.d("FASEL_DEBUG", "Proxy fail for $url : ${e.message}")
                            return null
                        }
                    }

                    // proxy other player resources to ensure correct headers
                    if (method.equals("GET", ignoreCase = true) &&
                        (lower.contains("fasel") || lower.contains("jwplayer") || lower.contains("config") || lower.contains("player"))
                    ) {
                        try {
                            val reqBuilder = OkRequest.Builder().url(url)
                                .header("User-Agent", lastValidUserAgent)
                                .header("Referer", referer)
                                .header("Origin", mainUrl)
                            try { cookieManager.getCookie(url)?.let { ck -> reqBuilder.header("Cookie", ck) } } catch (_: Exception) {}
                            val response = client.newCall(reqBuilder.build()).execute()
                            response.headers("Set-Cookie").forEach { try { cookieManager.setCookie(url, it) } catch (_: Exception) {} }
                            val contentType = response.header("content-type")?.split(";")?.first() ?: "text/html"
                            val encoding = "utf-8"
                            val stream = response.body?.byteStream()
                            return WebResourceResponse(contentType, encoding, stream)
                        } catch (e: Exception) {
                            return super.shouldInterceptRequest(view, request)
                        }
                    }

                    return super.shouldInterceptRequest(view, request)
                }
            }

            // assign shared client to main webView
            webView.webViewClient = sharedWebViewClient

            // WebChromeClient to capture console logs from injected JS
            webView.webChromeClient = object : WebChromeClient() {
                override fun onConsoleMessage(cm: ConsoleMessage?): Boolean {
                    val msg = cm?.message() ?: ""
                    try {
                        if (msg.startsWith("NET_M3U8::")) {
                            val url = msg.substringAfter("NET_M3U8::").trim()
                            val clean = url.substringBefore("?")
                            if (clean.endsWith(".m3u8")) {
                                synchronized(foundM3u8) {
                                    if (!foundM3u8.contains(url)) foundM3u8.add(url)
                                }
                                // quick finish for master/playlist/index
                                if (clean.contains("master") || clean.contains("playlist") || clean.contains("index")) {
                                    finishRunnable?.let { handler.removeCallbacks(it) }
                                    finishRunnable = Runnable { chooseAndFinish() }
                                    handler.postDelayed(finishRunnable!!, 600)
                                } else {
                                    if (finishRunnable == null) {
                                        finishRunnable = Runnable { chooseAndFinish() }
                                        handler.postDelayed(finishRunnable!!, 3000)
                                    }
                                }
                            }
                        } else if (msg.startsWith("JW_M3U8::")) {
                            val url = msg.removePrefix("JW_M3U8::").trim()
                            val clean = url.substringBefore("?")
                            if (clean.endsWith(".m3u8")) {
                                synchronized(foundM3u8) {
                                    if (!foundM3u8.contains(url)) foundM3u8.add(url)
                                }
                                finishRunnable?.let { handler.removeCallbacks(it) }
                                finishRunnable = Runnable { chooseAndFinish() }
                                handler.postDelayed(finishRunnable!!, 600)
                            }
                        }
                    } catch (_: Exception) {}
                    return true
                }

                override fun onCreateWindow(
                    view: WebView?,
                    isDialog: Boolean,
                    isUserGesture: Boolean,
                    resultMsg: android.os.Message?
                ): Boolean {
                    try {
                        val transport = resultMsg?.obj as? WebView.WebViewTransport
                        val newWebView = WebView(activity).apply {
                            layoutParams = FrameLayout.LayoutParams(1, 1, Gravity.START or Gravity.TOP)
                            visibility = View.INVISIBLE
                        }
                        newWebView.settings.apply {
                            javaScriptEnabled = true
                            domStorageEnabled = true
                            mediaPlaybackRequiresUserGesture = false
                            loadWithOverviewMode = true
                            useWideViewPort = true
                            mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
                            userAgentString = lastValidUserAgent
                        }
                        // attach newWebView to view hierarchy quietly
                        try {
                            val decor = activity.window?.decorView as? ViewGroup
                            decor?.addView(newWebView)
                        } catch (_: Exception) {}
                        // assign same clients (use shared reference)
                        newWebView.webViewClient = sharedWebViewClient
                        newWebView.webChromeClient = this
                        transport?.webView = newWebView
                        resultMsg?.sendToTarget()
                        return true
                    } catch (e: Exception) {
                        Log.d("FASEL_DEBUG", "onCreateWindow failed: ${e.message}")
                        return false
                    }
                }
            }

            // Load iframe using referer header
            val finalUrl = iframeUrl.replace("&amp;", "&").trim()
            try {
                webView.loadUrl(finalUrl, mapOf("Referer" to referer))
            } catch (e: Exception) {
                safeFinish(null)
            }

            // cancellation handling
            cont.invokeOnCancellation {
                handler.post { safeFinish(null) }
            }
        }
    }
