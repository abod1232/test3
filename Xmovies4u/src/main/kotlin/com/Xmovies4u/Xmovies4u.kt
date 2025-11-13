package com.wecima // تم تصحيح اسم الحزمة

import com.lagradost.cloudstream3.*
import com.lagradost.cloudstream3.utils.*
import org.jsoup.nodes.Element
import com.lagradost.cloudstream3.network.post
import com.fasterxml.jackson.annotation.JsonProperty
import android.util.Base64

class WecimaProvider : MainAPI() {
    override var mainUrl = "https://wecima.ac"
    override var name = "We Cima"
    override val hasMainPage = true
    override var lang = "ar"
    override val supportedTypes = setOf(
        TvType.Movie,
        TvType.TvSeries
    )

    override val mainPage = mainPageOf(
        "$mainUrl/seriestv" to "أحدث المسلسلات",
        "$mainUrl/movies" to "أحدث الأفلام",
        "$mainUrl/category/arabic-movies" to "أفلام عربي",
        "$mainUrl/category/foreign-movies" to "أفلام أجنبي",
        "$mainUrl/category/arabic-series" to "مسلسلات عربية",
        "$mainUrl/category/foreign-series" to "مسلسلات أجنبية"
    )

    override suspend fun getMainPage(page: Int, request: MainPageRequest): HomePageResponse {
        val document = app.get(request.data).document
        val home = document.select("div.Grid--WecimaPosts div.GridItem").mapNotNull {
            it.toSearchResult()
        }
        return newHomePageResponse(request.name, home)
    }

    private fun Element.toSearchResult(): SearchResponse? {
        val titleElement = this.selectFirst("h2") ?: this.selectFirst("strong") ?: return null
        val title = titleElement.text().trim()
        val href = this.selectFirst("a")?.attr("href") ?: return null
        val posterUrl = this.selectFirst("span.BG--GridItem")?.let {
            val style = it.attr("style")
            Regex("url\\((.*?)\\)").find(style)?.groupValues?.get(1)
        } ?: this.selectFirst("span.BG--GridItem")?.attr("data-src")

        return if (href.contains("/series/")) {
            newTvSeriesSearchResponse(title, href, TvType.TvSeries) {
                this.posterUrl = posterUrl
            }
        } else {
            newMovieSearchResponse(title, href, TvType.Movie) {
                this.posterUrl = posterUrl
            }
        }
    }

    override suspend fun search(query: String): List<SearchResponse> {
        val url = "$mainUrl/search"
        val response = app.post(
            url,
            data = mapOf("q" to query),
            referer = "$mainUrl/"
        ).parsed<SearchRoot>()

        val html = response.output.joinToString("")
        val document = org.jsoup.Jsoup.parse(html)

        return document.select("div.GridItem").mapNotNull {
            it.toSearchResult()
        }
    }

    data class SearchRoot (
        @JsonProperty("output" ) val output : ArrayList<String> = arrayListOf()
    )

    override suspend fun load(url: String): LoadResponse {
        val document = app.get(url).document

        val title = document.selectFirst("div.Title--Content--Single-begin h1")?.text()?.trim() ?: ""
        val posterStyle = document.selectFirst("wecima.separated--top")?.attr("style")
        val posterUrl = Regex("url\\((.*?)\\)").find(posterStyle ?: "")?.groupValues?.get(1)
        val plot = document.selectFirst("div.StoryMovieContent")?.text()?.trim()
        val year = document.select("ul.Terms--Content--Single-begin li")
            .find { it.selectFirst("span")?.text()?.contains("السنة") == true }
            ?.selectFirst("p")?.text()?.toIntOrNull()

        val isMovie = !url.contains("/series/")

        if (isMovie) {
            return newMovieLoadResponse(title, url, TvType.Movie, url) {
                this.posterUrl = posterUrl
                this.plot = plot
                this.year = year
            }
        } else {
            val episodes = mutableListOf<Episode>()
            val seasonElements = document.select("div.List--Seasons--Episodes a.SeasonsEpisodes")

            if (seasonElements.isNotEmpty()) {
                seasonElements.apmap { seasonEl ->
                    val seasonNum = Regex("الموسم (\\d+)").find(seasonEl.text())?.groupValues?.get(1)?.toIntOrNull()
                    val dataId = seasonEl.attr("data-id")
                    val dataSeason = seasonEl.attr("data-season")

                    val seasonPage = app.post(
                        "$mainUrl/ajax/Episode",
                        data = mapOf("post_id" to dataId, "season" to dataSeason)
                    ).document

                    seasonPage.select("a.hoverable.activable").forEach { epEl ->
                        val epTitle = epEl.selectFirst("episodetitle")?.text() ?: ""
                        val epNum = Regex("الحلقة (\\d+)").find(epTitle)?.groupValues?.get(1)?.toIntOrNull()
                        val epHref = epEl.attr("href")
                        episodes.add(
                            newEpisode(epHref) {
                                name = epTitle
                                season = seasonNum
                                episode = epNum
                            }
                        )
                    }
                }
            } else {
                 document.select(".EpisodesList.Full--Width a").forEach { epEl ->
                    val epTitle = epEl.selectFirst("episodetitle")?.text() ?: ""
                    val epNum = Regex("الحلقة (\\d+)").find(epTitle)?.groupValues?.get(1)?.toIntOrNull()
                    val epHref = epEl.attr("href")
                    episodes.add(
                        newEpisode(epHref) {
                            name = epTitle
                            season = 1 // Default to season 1
                            episode = epNum
                        }
                    )
                }
            }

            return newTvSeriesLoadResponse(title, url, TvType.TvSeries, episodes.sortedBy { it.episode }) {
                this.posterUrl = posterUrl
                this.plot = plot
                this.year = year
            }
        }
    }

    override suspend fun loadLinks(
        data: String,
        isCasting: Boolean,
        subtitleCallback: (SubtitleFile) -> Unit,
        callback: (ExtractorLink) -> Unit
    ): Boolean {
        val document = app.get(data).document

        document.select("ul.WatchServersList li btn").apmap {
            val encodedUrl = it.attr("data-url")
            // Wecima's Base64 is a bit weird, manually fix it.
            val fixedEncodedUrl = encodedUrl.replace(" ", "+")
            try {
                // The URL is plain Base64, but needs decoding.
                val decodedUrl = String(Base64.decode(fixedEncodedUrl, Base64.DEFAULT))
                if (decodedUrl.startsWith("http")) {
                   loadExtractor(decodedUrl, mainUrl, subtitleCallback, callback)
                }
            } catch (e: Exception) {
                logError(e)
            }
        }
        return true
    }
}        val document = app.get("$mainUrl${request.data}/page/$page").document
        val home     = document.select("article.post").mapNotNull { it.toSearchResult() }

        return newHomePageResponse(
                list    = HomePageList(
                name    = request.name,
                list    = home,
                isHorizontalImages = true
            ),
            hasNext = true
        )
    }

    private fun Element.toSearchResult(): SearchResponse {
        val title     = this.select("a").attr("title")
        val href      = this.select("a").attr("href")
        val posterUrl = this.select("a > img").attr("src")

        return newMovieSearchResponse(title, href, TvType.NSFW) {
            this.posterUrl = posterUrl
        }
    }

    override suspend fun search(query: String, page: Int): SearchResponseList? {
        val document = app.get("$mainUrl/page/$page/?s=$query").document
        val results = document.select("article.post").mapNotNull { it.toSearchResult() }
        val hasNext = if(results.isEmpty()) false else true
        return newSearchResponseList(results, hasNext)
    }

    override suspend fun load(url: String): LoadResponse {
        val document = app.get(url).document
        val title       = document.select("meta[property=og:title]").attr("content")
        val poster      = document.select("meta[property='og:image']").attr("content")
        val description = document.select("meta[property=og:description]").attr("content")

        return newMovieLoadResponse(title, url, TvType.NSFW, url) {
            this.posterUrl = poster
            this.plot      = description
        }
    }

    override suspend fun loadLinks(data: String, isCasting: Boolean, subtitleCallback: (SubtitleFile) -> Unit, callback: (ExtractorLink) -> Unit): Boolean {
        val document = app.get(data).document
        document.select("span > span > a").amap {
            loadExtractor(
                it.attr("href"),
                "$mainUrl/",
                subtitleCallback,
                callback
            )
        }
        return true
    }
}

class BigwrapPro : BigwarpIO() {
    override var mainUrl = "https://bigwarp.pro"
}

class Vide0 : DoodLaExtractor() {
    override var mainUrl = "https://vide0.net"
}

class Streamtapeadblockuser : StreamTape() {
    override var mainUrl = "https://streamtapeadblockuser.art"
}

class MixdropAG : MixDrop() {
    override var mainUrl = "https://mixdrop.ag"
}
