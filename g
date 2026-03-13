package com.mycima

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import android.webkit.CookieManager
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.LinearLayout
import android.widget.TextView
import com.lagradost.cloudstream3.*
import com.lagradost.cloudstream3.utils.*
import com.mycima.ExternalEarnVidsExtractor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element
import java.net.URLEncoder
import kotlin.coroutines.resume

class MyCimaProvider(private val context: Context) : MainAPI() {
    override var lang = "ar"
    override var mainUrl = "https://mycima.boo"
    override var name = "MyCima"
    override val usesWebView = false
    override val hasMainPage = true
    override val supportedTypes = setOf(TvType.TvSeries, TvType.Movie, TvType.Anime, TvType.AsianDrama)

    companion object {
        const val TAG = "MyCima"
        var redirectUrl: String? = null
        // القفل الموحد لضمان فتح WebView واحد فقط في كل مرة
        private val cfLock = Mutex()
        private var lastValidUserAgent =
            "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"
    }
    private suspend fun baseUrl(): String {
        redirectUrl?.let { return it }

        return try {
            val response = app.get(mainUrl, allowRedirects = true)
            val finalUrl = response.url

            val base = try {
                val uri = java.net.URI(finalUrl)
                "${uri.scheme}://${uri.host}"
            } catch (e: Exception) {
                mainUrl
            }

            redirectUrl = base
            Log.d(TAG, "Resolved main domain: $base")

            base
        } catch (e: Exception) {
            mainUrl
        }
    }



    // ================================
    //     Smart Cloudflare Bypass (Visible & Singleton)
    // ================================

    // دالة للتعرف على صفحة كلاودفلير
    private fun isCloudflareChallenge(html: String, title: String): Boolean {
        return (title.contains("Just a moment", ignoreCase = true) ||
                title.contains("Attention Required", ignoreCase = true) ||
                html.contains("cf-turnstile") ||
                html.contains("challenge-platform")) &&
                !html.contains("Grid--WecimaPosts")
    }

    // بناء الهيدرات بشكل موحد مع تثبيت الـ Referer
    private fun getHeaders(referer: String? = null): Map<String, String> {
        val cookies = CookieManager.getInstance().getCookie(redirectUrl ?: "") ?: ""

        val map = mutableMapOf(
            "User-Agent" to lastValidUserAgent,
            "Accept" to "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
            "Accept-Language" to "ar,en-US;q=0.9,en;q=0.8",
            "Upgrade-Insecure-Requests" to "1",
            "Cache-Control" to "no-cache",
            "Pragma" to "no-cache",
            "Referer" to (referer ?: redirectUrl ?: "")
        )

        if (cookies.isNotEmpty()) map["Cookie"] = cookies

        return map
    }

    @SuppressLint("SetTextI18n", "SetJavaScriptEnabled")
    private suspend fun fetchCookiesWithTrustedWebView(url: String, timeoutMs: Long = 30000L): Boolean = suspendCancellableCoroutine { cont ->
        Handler(Looper.getMainLooper()).post {
            val activity = context as? Activity
            if (activity == null || activity.isFinishing) {
                if (cont.isActive) cont.resume(false)
                return@post
            }


            // إعداد Dialog مخفي تماماً
            val dialog = Dialog(activity)
            dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)
            dialog.setCancelable(false)

            // إعدادات النافذة لتكون غير مرئية وغير قابلة للمس
            dialog.window?.apply {
                setBackgroundDrawableResource(android.R.color.transparent)
                clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND) // إزالة التعتيم الخلفي
                addFlags(
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                )
                // جعل الحجم 1 بكسل ووضعه خارج الشاشة
                val params = attributes
                params.width = 1
                params.height = 1
                params.gravity = Gravity.TOP or Gravity.START
                params.x = -1000
                params.y = -1000
                attributes = params
            }

            val webView = WebView(activity)
            // إخفاء الـ WebView
            webView.visibility = View.INVISIBLE
            dialog.setContentView(webView, ViewGroup.LayoutParams(1, 1))

            try {
                webView.settings.apply {
                    javaScriptEnabled = true
                    domStorageEnabled = true
                    databaseEnabled = true
                    useWideViewPort = true
                    loadWithOverviewMode = true
                    userAgentString = com.mycima.MyCimaProvider.Companion.lastValidUserAgent
                    cacheMode = WebSettings.LOAD_DEFAULT
                }
            } catch (_: Exception) {}

            val cookieManager = CookieManager.getInstance()
            try {
                cookieManager.setAcceptCookie(true)
                cookieManager.setAcceptThirdPartyCookies(webView, true)
            } catch (_: Exception) {}

            var finished = false

            fun finish(success: Boolean) {
                if (finished) return
                finished = true
                try { cookieManager.flush() } catch (_: Exception) {}
                try { if (dialog.isShowing) dialog.dismiss() } catch (_: Exception) {}
                try { webView.stopLoading() } catch (_: Exception) {}
                try { webView.destroy() } catch (_: Exception) {}
                if (cont.isActive) cont.resume(success)
            }

            val startTime = System.currentTimeMillis()
            val handler = Handler(Looper.getMainLooper())

            val checker = object : Runnable {
                override fun run() {
                    if (finished) return

                    val currentCookies = try { cookieManager.getCookie(url) } catch (e: Exception) { "" } ?: ""

                    // التحقق من وجود cf_clearance فقط
                    if (currentCookies.contains("cf_clearance")) {
                        Log.d(com.mycima.MyCimaProvider.Companion.TAG, "Hidden Cloudflare Bypass Successful!")
                        handler.postDelayed({ finish(true) }, 1000)
                        return
                    }

                    if (System.currentTimeMillis() - startTime > timeoutMs) {
                        Log.d(com.mycima.MyCimaProvider.Companion.TAG, "Hidden Cloudflare Bypass Timeout!")
                        finish(false)
                        return
                    }
                    handler.postDelayed(this, 1000)
                }
            }

            handler.postDelayed(checker, 1000)
            webView.webViewClient = object : WebViewClient() {}

            try {
                dialog.show()
                // تمرير Referer مهم جداً
                webView.loadUrl(url, mutableMapOf("Referer" to redirectUrl))
            } catch (e: Exception) {
                finish(false)
            }

            cont.invokeOnCancellation {
                handler.post { finish(false) }
            }
        }
    }

    // ================================
    //     Smart Networking (Retries -> Then WebView)
    // ================================

    private suspend fun smartGet(url: String, referer: String? = null, timeoutSeconds: Long = 20000L): Document {
        // المحاولة 1 و 2: طلبات عادية
        var currentAttempt = 0
        val normalRetries = 2

        while (currentAttempt < normalRetries) {
            currentAttempt++
            try {
                val response = app.get(url, headers = getHeaders(referer), timeout = timeoutSeconds, cacheTime = 0)

                if (response.code == 200 && !isCloudflareChallenge(response.text, response.document.title())) {
                    return response.document
                } else {
                    Log.d(com.mycima.MyCimaProvider.Companion.TAG, "Attempt $currentAttempt failed (Code: ${response.code}). Retrying silently...")
                    kotlinx.coroutines.delay(1500)
                }
            } catch (e: Exception) {
                Log.d(com.mycima.MyCimaProvider.Companion.TAG, "Attempt $currentAttempt Exception: ${e.message}")
                kotlinx.coroutines.delay(1500)
            }
        }

        // المحاولة 3: استنفذنا المحاولات، نفتح الـ WebView المخفي
        Log.d(com.mycima.MyCimaProvider.Companion.TAG, "Normal retries failed. Activating Hidden WebView Bypass...")

        com.mycima.MyCimaProvider.Companion.cfLock.withLock {
            try {
                val check = app.get(url, headers = getHeaders(referer), timeout = 10000L, cacheTime = 0)
                if (check.code == 200 && !isCloudflareChallenge(check.text, "")) return check.document
            } catch (_: Exception) {}

            // استدعاء الدالة المخفية (Timeout = 30s)
            fetchCookiesWithTrustedWebView(url, timeoutMs = 30000L)
        }

        return try {
            app.get(url, headers = getHeaders(referer), timeout = timeoutSeconds, cacheTime = 0).document
        } catch (e: Exception) {
            Jsoup.parse("<html><body>Error loading page</body></html>", url)
        }
    }

    private suspend fun smartPost(url: String, data: Map<String, String>, referer: String? = null, timeoutSeconds: Long = 20000L): Document {
        // الـ POST حساس، نحاول مرة واحدة ثم WebView إذا فشل
        try {
            val headers = getHeaders(referer).toMutableMap()
            headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
            headers["X-Requested-With"] = "XMLHttpRequest"

            val response = app.post(url, data = data, headers = headers, timeout = timeoutSeconds, cacheTime = 0)
            if (!isCloudflareChallenge(response.text, "")) {
                return response.document
            }
        } catch (e: Exception) {}
        val baseUrl = redirectUrl ?: return Jsoup.parse("", "")
        com.mycima.MyCimaProvider.Companion.cfLock.withLock {
            try {
                val baseUrl = redirectUrl ?: return Jsoup.parse("", "")

                val checkResponse = app.get(
                    baseUrl,
                    headers = getHeaders(referer),
                    timeout = timeoutSeconds,
                    cacheTime = 0
                )

                if (isCloudflareChallenge(checkResponse.text, "")) {
                    fetchCookiesWithTrustedWebView(baseUrl, timeoutMs = 30000L)
                }

            } catch (e: Exception) {
                val baseUrl = redirectUrl ?: return Jsoup.parse("", "")
                fetchCookiesWithTrustedWebView(baseUrl, timeoutMs = 30000L)
            }
        }

        return try {
            val retryHeaders = getHeaders(referer).toMutableMap()
            retryHeaders["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
            retryHeaders["X-Requested-With"] = "XMLHttpRequest"
            app.post(url, data = data, headers = retryHeaders, timeout = timeoutSeconds, cacheTime = 0).document
        } catch (e: Exception) {
            Jsoup.parse("", url)
        }
    }

    private fun extractNumbers(text: String?): Int? {
        if (text.isNullOrBlank()) return null
        return Regex("""\d+""").find(text)?.value?.toIntOrNull()
    }

    private fun String.safeBase64Decode(): String {
        return try {
            String(Base64.decode(this, Base64.DEFAULT), Charsets.UTF_8)
        } catch (e: Exception) { "" }
    }

    private fun getPosterFromStyle(element: Element?): String? {
        val style = element?.attr("style")?.ifBlank { null } ?: element?.attr("data-lazy-style")
        return style?.let {
            Regex("""url\((.*?)\)""").find(it)?.groupValues?.get(1)
                ?.trim('\'', '"', ' ')
                ?.ifBlank { null }
        }
    }

    private fun extractServerName(element: Element): String {
        return (element.ownText().ifBlank { element.text() }).replace(Regex("\\s+"), " ").trim()
    }

    private fun String.encodeURL(): String {
        return try {
            URLEncoder.encode(this, "UTF-8")
        } catch (e: Exception) { this }
    }

    private fun Element.toSearchResult(): SearchResponse? {
        val linkElement = this.selectFirst("div.Thumb--GridItem a") ?: return null
        val url = linkElement.attr("href")
        if (url.isBlank()) return null

        val posterUrl = getPosterFromStyle(linkElement.selectFirst("span.BG--GridItem"))
        val titleTag = linkElement.selectFirst("strong") ?: return null
        val title = titleTag.ownText().trim()
        val year = titleTag.selectFirst("span.year")?.text()?.let { extractNumbers(it) }

        val isMovie = this.selectFirst("div.Episode--number") == null && !url.contains("/series/")

        return if (isMovie) {
            newMovieSearchResponse(title, url, TvType.Movie) {
                this.posterUrl = posterUrl
                this.year = year
            }
        } else {
            newTvSeriesSearchResponse(title, url, TvType.TvSeries) {
                this.posterUrl = posterUrl
                this.year = year
            }
        }
    }

    // ================================
    //     Main Page
    // ================================

    override val mainPage = mainPageOf(
        "$redirectUrl/" to "احدث الاضافات",
        "$redirectUrl/movies/" to "افلام جديدة",
        "$redirectUrl/series/" to "مسلسلات جديدة",
        "$redirectUrl/category/افلام-اجنبي/" to "افلام اجنبي",
        "$redirectUrl/category/مسلسلات-عربي/" to "مسلسلات عربي",
        "$redirectUrl/category/افلام-انمي/" to "أفلام أنمي",
        "$redirectUrl/category/مسلسلات-انمي/" to "مسلسلات أنمي",
    )

    override suspend fun getMainPage(page: Int, request: MainPageRequest): HomePageResponse {
        return try {
            val url = if (page > 1) {
                "${request.data.removeSuffix("/")}/page/$page/"
            } else {
                request.data
            }

            val document = smartGet(url)

            val isBannerRequest = request.name == "احدث الاضافات" && page == 1
            val selector = "div.Grid--WecimaPosts div.GridItem, div#MainFiltar div.GridItem, div.Slider--Grid div.GridItem"
            val list = document.select(selector).mapNotNull { it.toSearchResult() }

            val homePageList = HomePageList(
                name = request.name,
                list = list,
                isHorizontalImages = isBannerRequest
            )

            newHomePageResponse(homePageList)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load page $page for ${request.name}", e)
            val homePageList = HomePageList(
                name = request.name,
                list = emptyList(),
                isHorizontalImages = false
            )
            newHomePageResponse(homePageList)
        }
    }

    override suspend fun search(query: String): List<SearchResponse> {
        val url = "$redirectUrl/filtering/?keywords=${query.encodeURL()}"
        val document = smartGet(url)
        return document.select("div#MainFiltar div.GridItem").mapNotNull { it.toSearchResult() }
    }

    override suspend fun load(url: String): LoadResponse? {
        // 1. إضافة try-catch شاملة لتطويق الدالة بالكامل
        return try {
            val document = smartGet(url)

            // ------------------------------------------------------------------
            // 2. إصلاح استخراج العنوان (Fallback) لضمان عدم التوقف
            // ------------------------------------------------------------------
            var title = document.selectFirst("div.Title--Content--Single-begin > h1")?.ownText()?.trim()

            // إذا فشل المحدد الأول، نستخدم Meta Tags
            if (title.isNullOrBlank()) {
                title = document.selectFirst("meta[property='og:title']")?.attr("content")?.trim()
                // تنظيف العنوان من اسم الموقع ليكون نظيفاً
                title = title?.replace(" - وي سيما WECIMA ماي سيما MYCIMA", "")
                    ?.replace(" - ماي سيما", "")
            }

            // محاولة أخيرة من عنوان الصفحة
            if (title.isNullOrBlank()) {
                title = document.title()
            }

            // إذا بقي العنوان فارغاً بعد كل المحاولات، نتوقف
            if (title.isNullOrBlank()) return null
            // ------------------------------------------------------------------

            val poster = getPosterFromStyle(document.selectFirst("wecima.separated--top"))
            val year = document.selectFirst("div.Title--Content--Single-begin h1 a")?.text()?.toIntOrNull()
            val plot = document.selectFirst("div.StoryMovieContent")?.text()?.trim()
            val tags = document.select("ul.Terms--Content--Single-begin li:has(span:contains(النوع)) p a").map { it.text() }
            val recommendations = document.select("div.Grid--WecimaPosts div.GridItem").mapNotNull { it.toSearchResult() }

            val isSeriesPage = document.selectFirst("div.SeasonsList, .Seasons--Episodes") != null
            val seriesUrlFromEpisode = document.selectFirst("ul.Terms--Content--Single-begin li:contains(المسلسل) a")?.attr("href")

            // --- دوال مساعدة داخلية ---
            fun extractPostId(doc: org.jsoup.nodes.Document): String? {
                doc.selectFirst("input[name=post_id]")?.attr("value")?.takeIf { it.isNotBlank() }?.let { return it }
                doc.selectFirst("[data-post_id]")?.attr("data-post_id")?.takeIf { it.isNotBlank() }?.let { return it }
                doc.selectFirst("[data-postid]")?.attr("data-postid")?.takeIf { it.isNotBlank() }?.let { return it }
                doc.selectFirst("meta[name=post_id]")?.attr("content")?.takeIf { it.isNotBlank() }?.let { return it }
                val scriptsText = doc.select("script").joinToString(" ") { it.data() ?: "" }
                Regex("""post_id['"]?\s*[:=]\s*['"]?(\d{3,})['"]?""").find(scriptsText)?.groups?.get(1)?.value?.let { return it }
                Regex("""postid['"]?\s*[:=]\s*['"]?(\d{3,})['"]?""").find(scriptsText)?.groups?.get(1)?.value?.let { return it }
                return null
            }

            fun extractEpisodeNumberFromText(text: String?): String? {
                if (text.isNullOrBlank()) return null
                Regex("""الحلقة\s*(\d+)""").find(text)?.groups?.get(1)?.value?.let { return it }
                Regex("""\b(\d{1,3})\b""").find(text)?.groups?.get(1)?.value?.let { return it }
                return null
            }

            fun resolveUrl(base: String, relative: String): String {
                return try {
                    val u = java.net.URL(java.net.URL(base), relative)
                    u.toString()
                } catch (e: Exception) {
                    val base = redirectUrl ?: mainUrl
                    if (relative.startsWith("http")) relative else base.trimEnd('/') + "/" + relative.trimStart('/')
                }
            }

            if (isSeriesPage) {
                val episodes = mutableListOf<Episode>()
                val postId = extractPostId(document)
                val ajaxUrl = "$redirectUrl/wp-content/themes/mycima/Ajaxt/Single/Episodes.php"

                var seasonAnchors = document.select("div.SeasonsList ul li a")
                if (seasonAnchors.isEmpty()) {
                    seasonAnchors = document.select(".Seasons--Episodes ul li a")
                }

                if (seasonAnchors.isEmpty()) {
                    val globalAnchors = document.select("div.EpisodesList a[href], a.episode[href]")
                    for (a in globalAnchors) {
                        val epTitleRaw = a.selectFirst(".episodetitle")?.text() ?: a.attr("title").ifBlank { a.text() }
                        val epNumText = extractEpisodeNumberFromText(epTitleRaw)
                        val epNum = epNumText?.toIntOrNull()
                        val newTitle = if (epNum != null) "الحلقة $epNum" else (epTitleRaw ?: "حلقة")
                        var epHref = a.attr("href").ifBlank { a.attr("data-href") }
                        if (epHref.isNullOrBlank()) continue
                        epHref = resolveUrl(url, epHref)
                        episodes.add(newEpisode(epHref) {
                            this.name = newTitle
                            this.season = null
                            this.episode = epNum
                            this.posterUrl = poster
                        })
                    }

                    val distinctEpisodes = episodes.distinctBy { it.data }
                    return newTvSeriesLoadResponse(title!!, url, TvType.TvSeries, distinctEpisodes) {
                        this.posterUrl = poster
                        this.year = year
                        this.plot = plot
                        this.tags = tags
                        this.recommendations = recommendations
                    }
                }

                for ((seasonIndex, seasonEl) in seasonAnchors.withIndex()) {
                    val rawSeasonText = seasonEl.text().trim()
                    val seasonIdRaw = seasonEl.attr("data-season").ifBlank { seasonEl.attr("data-season-id") }
                    val seasonHrefRaw = seasonEl.attr("href").ifBlank { seasonEl.attr("data-href") }

                    val seasonNumFromText = extractNumbers(rawSeasonText)
                    val seasonNumFromId = extractNumbers(seasonIdRaw)?.takeIf { seasonIdRaw.length <= 3 }
                    val seasonNumber = seasonNumFromText ?: seasonNumFromId ?: (seasonIndex + 1)

                    val seasonLabel = when {
                        rawSeasonText.isNotBlank() && !rawSeasonText.matches(Regex("^\\d{3,}\$")) -> {
                            if (rawSeasonText.matches(Regex("^\\d{1,3}\$"))) "الموسم $rawSeasonText" else rawSeasonText
                        }
                        else -> "الموسم $seasonNumber"
                    }

                    var gotEpisodesForThisSeason = false
                    var localEpisodeCounter = 0

                    if (seasonIdRaw.isNotBlank() && !postId.isNullOrBlank()) {
                        try {
                            val postData = mapOf("season" to seasonIdRaw, "post_id" to postId)
                            val seasonDoc = smartPost(ajaxUrl, data = postData, referer = url, timeoutSeconds = 10_000L)
                            val anchors = seasonDoc.select("a[href]").ifEmpty { seasonDoc.select("div.EpisodesList a[href]") }
                            if (anchors.isNotEmpty()) {
                                for (a in anchors) {
                                    val epTitleRaw = a.selectFirst(".episodetitle")?.text() ?: a.attr("title").ifBlank { a.text() }
                                    val epNumText = extractEpisodeNumberFromText(epTitleRaw)
                                    val epNum = epNumText?.toIntOrNull() ?: run {
                                        localEpisodeCounter += 1
                                        localEpisodeCounter
                                    }
                                    var epHref = a.attr("href").ifBlank { a.attr("data-href") }
                                    if (epHref.isNullOrBlank()) continue
                                    epHref = resolveUrl(url, epHref)
                                    episodes.add(newEpisode(epHref) {
                                        this.name = "$seasonLabel الحلقة $epNum"
                                        this.season = seasonNumber
                                        this.episode = epNum
                                        this.posterUrl = poster
                                    })
                                }
                                gotEpisodesForThisSeason = true
                            }
                        } catch (_: Exception) {}
                    }

                    if (gotEpisodesForThisSeason) continue

                    if (!seasonHrefRaw.isNullOrBlank()) {
                        try {
                            val resolvedSeasonHref = resolveUrl(url, seasonHrefRaw)
                            val seasonDoc = smartGet(resolvedSeasonHref, referer = url, timeoutSeconds = 10_000L)
                            val anchors = seasonDoc.select("div.EpisodesList a[href], a[href]").filter {
                                it.closest(".SeasonsList") == null
                            }
                            if (anchors.isNotEmpty()) {
                                for (a in anchors) {
                                    val epTitleRaw = a.selectFirst(".episodetitle")?.text() ?: a.attr("title").ifBlank { a.text() }
                                    val epNumText = extractEpisodeNumberFromText(epTitleRaw)
                                    val epNum = epNumText?.toIntOrNull() ?: run {
                                        localEpisodeCounter += 1
                                        localEpisodeCounter
                                    }
                                    var epHref = a.attr("href").ifBlank { a.attr("data-href") }
                                    if (epHref.isNullOrBlank()) continue
                                    epHref = resolveUrl(url, epHref)
                                    episodes.add(newEpisode(epHref) {
                                        this.name = "$seasonLabel الحلقة $epNum"
                                        this.season = seasonNumber
                                        this.episode = epNum
                                        this.posterUrl = poster
                                    })
                                }
                                gotEpisodesForThisSeason = true
                            }
                        } catch (_: Exception) {}
                    }

                    if (gotEpisodesForThisSeason) continue

                    val fallbackBlocks = document.select("div.SeasonsList, .Seasons--Episodes")
                    if (fallbackBlocks.isNotEmpty()) {
                        val matchingBlock = fallbackBlocks.getOrNull(seasonIndex) ?: fallbackBlocks.firstOrNull()
                        matchingBlock?.select("div.EpisodesList a[href], a[href]")?.let { anchors ->
                            if (anchors.isNotEmpty()) {
                                for (a in anchors) {
                                    val epTitleRaw = a.selectFirst(".episodetitle")?.text() ?: a.attr("title").ifBlank { a.text() }
                                    val epNumText = extractEpisodeNumberFromText(epTitleRaw)
                                    val epNum = epNumText?.toIntOrNull() ?: run {
                                        localEpisodeCounter += 1
                                        localEpisodeCounter
                                    }
                                    var epHref = a.attr("href").ifBlank { a.attr("data-href") }
                                    if (epHref.isNullOrBlank()) continue
                                    epHref = resolveUrl(url, epHref)
                                    episodes.add(newEpisode(epHref) {
                                        this.name = "$seasonLabel الحلقة $epNum"
                                        this.season = seasonNumber
                                        this.episode = epNum
                                        this.posterUrl = poster
                                    })
                                }
                                gotEpisodesForThisSeason = true
                            }
                        }
                    }
                }

                // ترتيب الحلقات لضمان عدم التداخل
                val distinctEpisodes = episodes.distinctBy { it.data }
                    .sortedWith(compareBy({ it.season }, { it.episode }))

                return newTvSeriesLoadResponse(title!!, url, TvType.TvSeries, distinctEpisodes) {
                    this.posterUrl = poster
                    this.year = year
                    this.plot = plot
                    this.tags = tags
                    this.recommendations = recommendations
                }
            } else if (seriesUrlFromEpisode != null) {
                return load(seriesUrlFromEpisode)
            } else {
                return newMovieLoadResponse(title!!, url, TvType.Movie, url) {
                    this.posterUrl = poster
                    this.year = year
                    this.plot = plot
                    this.tags = tags
                    this.recommendations = recommendations
                }
            }
        } catch (e: Exception) {
            // هنا يطبع الخطأ في Logcat في حال حدوثه بدلاً من توقف التطبيق
            Log.e(TAG, "Error loading page: $url", e)
            e.printStackTrace()
            return null
        }
    }

    override suspend fun loadLinks(
        data: String,
        isCasting: Boolean,
        subtitleCallback: (SubtitleFile) -> Unit,
        callback: (ExtractorLink) -> Unit
    ): Boolean {
        val document = try {
            smartGet(data)
        } catch (e: Exception) {
            return false
        }

        val linksToProcess = mutableListOf<Pair<String, String>>()

        document.select("ul#watch li[data-watch]").forEach {
            val url = it.attr("data-watch")
            val name = extractServerName(it)
            if (url.isNotBlank()) linksToProcess.add(url to name)
        }

        document.select("ul.List--Download--Wecima--Single li a[href]").forEach {
            val url = it.attr("href")
            val name = it.selectFirst("quality")?.text()?.trim() ?: "تحميل"
            if (url.isNotBlank()) linksToProcess.add(url to name)
        }

        coroutineScope {
            linksToProcess.distinctBy { it.first }.map { (link, serverName) ->
                async {
                    val finalUrl = if (link.contains("govid.site")) {
                        try {
                            val govidDoc = smartGet(link, referer = data)
                            govidDoc.selectFirst("iframe")?.attr("src")
                        } catch (e: Exception) {
                            null
                        }
                    } else if (link.contains("mycima.page/go/")) {
                        try {
                            val base64Part = link.substringAfterLast('/')
                            base64Part.safeBase64Decode()
                        } catch (e: Exception) {
                            null
                        }
                    } else {
                        link
                    }

                    if (!finalUrl.isNullOrBlank()) {
                        loadExtractor(finalUrl, data, subtitleCallback, callback)

                        // If it's a specific server, also try the custom extractor
                        if (serverName.equals("EarnVids", true) || serverName.equals("StreamHG", true)) {
                            try {
                                ExternalEarnVidsExtractor.extract(finalUrl, redirectUrl ?: mainUrl)?.let { customLink ->                                    callback.invoke(
                                        newExtractorLink(
                                            this@MyCimaProvider.name,
                                            "$serverName (مخصص)",
                                            customLink,
                                        ) {
                                            this.quality = Qualities.Unknown.value

                                        }
                                    )
                                }
                            } catch (e: Exception) {
                            }
                        }
                    }
                }
            }.awaitAll()
        }

        return true
    }
}
