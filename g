package com.cinemana

import android.content.Context
import android.os.Bundle
import android.util.Log
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.FragmentContainerView
import androidx.preference.PreferenceCategory
import androidx.preference.PreferenceFragmentCompat
import androidx.preference.PreferenceManager
import androidx.preference.SwitchPreferenceCompat
import com.google.android.material.bottomsheet.BottomSheetDialogFragment
import com.lagradost.cloudstream3.Actor
import com.lagradost.cloudstream3.ActorData
import com.lagradost.cloudstream3.*
import com.lagradost.cloudstream3.utils.ExtractorLink
import com.lagradost.cloudstream3.utils.Qualities
import com.lagradost.cloudstream3.utils.newExtractorLink
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.net.URLEncoder

class CinemanaSettings : BottomSheetDialogFragment() {
    class PrefsFragment : PreferenceFragmentCompat() {
        private val TAG = "CinemanaSettings"

        override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
            val context = requireContext()
            val screen = preferenceManager.createPreferenceScreen(context)
            preferenceScreen = screen

            fun createSwitch(title: String, key: String, default: Boolean): SwitchPreferenceCompat {
                val pref = SwitchPreferenceCompat(context)
                pref.key = key
                pref.title = title
                pref.setDefaultValue(default)
                pref.setOnPreferenceChangeListener { _, newValue ->
                    Log.d(TAG, "Setting CHANGED: $key -> $newValue")
                    true
                }
                return pref
            }

            val generalCat = PreferenceCategory(context).apply { title = "عام" }
            screen.addPreference(generalCat)

            generalCat.addPreference(createSwitch("البانر العلوي", "cine_banner", true))
            generalCat.addPreference(createSwitch("الصفحة الرئيسية (تلقائي)", "cine_dynamic_home", true))
            generalCat.addPreference(createSwitch("أحدث الإضافات (ثابت)", "cine_newly_added", false))

            val moviesCat = PreferenceCategory(context).apply { title = "الأفلام (ثابت)" }
            screen.addPreference(moviesCat)

            val movieSwitches = listOf(
                Triple("أفلام - تاريخ الرفع - الأحدث", "cine_mov_upload_desc", false),
                Triple("أفلام - تاريخ الرفع - الأقدم", "cine_mov_upload_asc", false),
                Triple("أفلام - الأكثر مشاهدة", "cine_mov_views_desc", false),
                Triple("أفلام - أعلى تقييم IMDb", "cine_mov_stars_desc", false),
                Triple("أفلام - أبجديًا (أ-ي)", "cine_mov_ar_asc", false),
                Triple("أفلام - أبجديًا (A-Z)", "cine_mov_en_asc", false)
            )
            movieSwitches.forEach { (title, key, def) ->
                moviesCat.addPreference(createSwitch(title, key, def))
            }

            val seriesCat = PreferenceCategory(context).apply { title = "المسلسلات (ثابت)" }
            screen.addPreference(seriesCat)

            val seriesSwitches = listOf(
                Triple("مسلسلات - تاريخ الرفع - الأحدث", "cine_ser_upload_desc", false),
                Triple("مسلسلات - تاريخ الرفع - الأقدم", "cine_ser_upload_asc", false),
                Triple("مسلسلات - الأكثر مشاهدة", "cine_ser_views_desc", false),
                Triple("مسلسلات - أعلى تقييم IMDb", "cine_ser_stars_desc", false),
                Triple("مسلسلات - أبجديًا (أ-ي)", "cine_ser_ar_asc", false),
                Triple("مسلسلات - أبجديًا (A-Z)", "cine_ser_en_asc", false)
            )
            seriesSwitches.forEach { (title, key, def) ->
                seriesCat.addPreference(createSwitch(title, key, def))
            }
        }
    }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        val fragmentContainer = FragmentContainerView(requireContext())
        fragmentContainer.id = View.generateViewId()
        return fragmentContainer
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        childFragmentManager.beginTransaction()
            .replace(view.id, PrefsFragment())
            .commit()
    }
}

class Cinemana(val context: Context) : MainAPI() {
    override var name = "Shabakaty Cinemana (\uD83C\uDDEE\uD83C\uDDF6)"
    override var mainUrl = "https://cinemana.shabakaty.cc"
    override var lang = "ar"
    override val supportedTypes = setOf(TvType.Movie, TvType.TvSeries)
    override val hasMainPage = true

    private val apiV2 = "$mainUrl/api/android"

    private data class Section(
        val title: String,
        val url: String,
        val prefKey: String,
        val defaultEnabled: Boolean = false
    )

    private val staticCategories = listOf(
        Section("أحدث الإضافات", "$apiV2/newlyVideosItems/level/0/offset/12/page/", "cine_newly_added", false),
        Section("أفلام - تاريخ الرفع - الأحدث", "$mainUrl/api/android/video/V/2?videoKind=1&langNb=&itemsPerPage=30&pageNumber=&level=0&sortParam=desc", "cine_mov_upload_desc", false),
        Section("أفلام - تاريخ الرفع - الأقدم", "$mainUrl/api/android/video/V/2?videoKind=1&langNb=&itemsPerPage=30&pageNumber=&level=0&sortParam=asc", "cine_mov_upload_asc", false),
        Section("أفلام - الأكثر مشاهدة", "$mainUrl/api/android/video/V/2?videoKind=1&langNb=&itemsPerPage=30&pageNumber=&level=0&sortParam=views_desc", "cine_mov_views_desc", false),
        Section("أفلام - أعلى تقييم IMDb", "$mainUrl/api/android/video/V/2?videoKind=1&langNb=&itemsPerPage=30&pageNumber=&level=0&sortParam=stars_desc", "cine_mov_stars_desc", false),
        Section("أفلام - أبجديًا (أ-ي)", "$mainUrl/api/android/video/V/2?videoKind=1&langNb=&itemsPerPage=30&pageNumber=&level=0&sortParam=ar_title_asc", "cine_mov_ar_asc", false),
        Section("أفلام - أبجديًا (A-Z)", "$mainUrl/api/android/video/V/2?videoKind=1&langNb=&itemsPerPage=30&pageNumber=&level=0&sortParam=en_title_asc", "cine_mov_en_asc", false),
        Section("مسلسلات - تاريخ الرفع - الأحدث", "$mainUrl/api/android/video/V/2?videoKind=2&langNb=&itemsPerPage=30&pageNumber=&level=0&sortParam=desc", "cine_ser_upload_desc", false),
        Section("مسلسلات - تاريخ الرفع - الأقدم", "$mainUrl/api/android/video/V/2?videoKind=2&langNb=&itemsPerPage=30&pageNumber=&level=0&sortParam=asc", "cine_ser_upload_asc", false),
        Section("مسلسلات - الأكثر مشاهدة", "$mainUrl/api/android/video/V/2?videoKind=2&langNb=&itemsPerPage=30&pageNumber=&level=0&sortParam=views_desc", "cine_ser_views_desc", false),
        Section("مسلسلات - أعلى تقييم IMDb", "$mainUrl/api/android/video/V/2?videoKind=2&langNb=&itemsPerPage=30&pageNumber=&level=0&sortParam=stars_desc", "cine_ser_stars_desc", false),
        Section("مسلسلات - أبجديًا (أ-ي)", "$mainUrl/api/android/video/V/2?videoKind=2&langNb=&itemsPerPage=30&pageNumber=&level=0&sortParam=en_title_desc", "cine_ser_ar_asc", false),
        Section("مسلسلات - أبجديًا (A-Z)", "$mainUrl/api/android/video/V/2?videoKind=2&langNb=&itemsPerPage=30&pageNumber=&level=0&sortParam=en_title_asc", "cine_ser_en_asc", false)
    )

    override val mainPage: List<MainPageData>
        get() {
            val prefs = PreferenceManager.getDefaultSharedPreferences(context)
            val generatedPages = mutableListOf<MainPageData>()

            if (prefs.getBoolean("cine_banner", true) || prefs.getBoolean("cine_dynamic_home", true)) {
                generatedPages.add(mainPageOf("CINE_DYNAMIC_HOME" to "الصفحة الرئيسية").first())
            }

            staticCategories.forEach { section ->
                if (prefs.getBoolean(section.prefKey, section.defaultEnabled)) {
                    generatedPages.add(mainPageOf(section.url to section.title).first())
                }
            }

            return generatedPages
        }

    override suspend fun getMainPage(page: Int, request: MainPageRequest): HomePageResponse = coroutineScope {
        val requestData = request.data ?: ""
        val requestName = request.name ?: "القسم"
        val prefs = PreferenceManager.getDefaultSharedPreferences(context)
        val items = mutableListOf<HomePageList>()

        if (requestData.isBlank()) {
            return@coroutineScope newHomePageResponse(emptyList(), hasNext = false)
        }

        if (requestData == "CINE_DYNAMIC_HOME") {
            if (page > 1) {
                return@coroutineScope newHomePageResponse(emptyList(), hasNext = false)
            }

            val bannerDeferred = async(Dispatchers.IO) {
                if (prefs.getBoolean("cine_banner", true)) {
                    try {
                        withTimeoutOrNull(3000) {
                            app.get("$apiV2/banner/level/0").parsedSafe<List<Map<String, Any>>>()
                        }
                    } catch (_: Exception) {
                        null
                    }
                } else null
            }

            val groupsDeferred = async(Dispatchers.IO) {
                if (prefs.getBoolean("cine_dynamic_home", true)) {
                    try {
                        withTimeoutOrNull(3000) {
                            app.get("$apiV2/videoGroups/lang/ar/level/0").parsedSafe<Map<String, Any>>()
                        }
                    } catch (_: Exception) {
                        null
                    }
                } else null
            }

            bannerDeferred.await()?.mapNotNull { it.toCinemanaItem().toSearchResponse() }
                ?.distinctBy { it.url }
                ?.takeIf { it.isNotEmpty() }
                ?.let { bannerList ->
                    items.add(HomePageList("المميز", bannerList, isHorizontalImages = true))
                }

            val responseMap = groupsDeferred.await()
            val groupsArray = responseMap?.get("groups") as? List<*> ?: emptyList<Any>()
            var addedAnyGroup = false

            for (groupRaw in groupsArray) {
                val group = groupRaw as? Map<*, *> ?: continue
                val title = group["title"] as? String ?: continue

                val groupId = when (val rawId = group["groupsID"]) {
                    is Number -> rawId.toInt().toString()
                    else -> rawId?.toString()
                } ?: (group["analytics"] as? Map<*, *>)?.get("eventInt")?.toString()
                    ?: group["list_id"]?.toString()
                    ?: continue

                val paginationUrl = "$apiV2/videoListPagination/groupID/$groupId/level/0/itemsPerPage/12/page/"

                val contentArray = group["content"] as? List<*> ?: emptyList<Any>()
                val parsedContent = contentArray.mapNotNull { itemRaw ->
                    (itemRaw as? Map<String, Any>)?.toCinemanaItem()?.toSearchResponse()
                }.distinctBy { it.url }

                if (parsedContent.isNotEmpty()) {
                    val hpList = HomePageList(title, parsedContent)
                    injectUrlToHomePageList(hpList, paginationUrl, title)
                    items.add(hpList)
                    addedAnyGroup = true
                }
            }

            if (!addedAnyGroup) {
                val fallbackSections = listOf(
                    Section("أفلام 4K", "$apiV2/videoListPagination/groupID/290/level/0/itemsPerPage/12/page/", "cine_dynamic_home", true),
                    Section("أحدث الأفلام", "$apiV2/videoListPagination/groupID/26/level/0/itemsPerPage/12/page/", "cine_dynamic_home", true),
                    Section("أحدث المسلسلات", "$apiV2/videoListPagination/groupID/311/level/0/itemsPerPage/12/page/", "cine_dynamic_home", true),
                    Section("أفلام كارتون", "$apiV2/videoListPagination/groupID/392/level/0/itemsPerPage/12/page/", "cine_dynamic_home", true)
                )

                for (section in fallbackSections) {
                    try {
                        val resp = withTimeoutOrNull(3000) {
                            app.get("${section.url}0/").parsedSafe<List<Map<String, Any>>>()
                        }
                        val parsed = resp?.mapNotNull { it.toCinemanaItem().toSearchResponse() }
                            ?.distinctBy { it.url }
                            ?: emptyList()

                        if (parsed.isNotEmpty()) {
                            val hpList = HomePageList(section.title, parsed)
                            injectUrlToHomePageList(hpList, section.url, section.title)
                            items.add(hpList)
                        }
                    } catch (_: Exception) {
                    }
                }
            }

            return@coroutineScope newHomePageResponse(items, hasNext = false)
        }

        if (requestData == "CINE_DYNAMIC_HOME" && page > 1) {
            return@coroutineScope newHomePageResponse(emptyList(), hasNext = false)
        }

        val apiPage = (page - 1).coerceAtLeast(0)

        val fetchUrl = when {
            requestData.contains("/page/") -> {
                if (requestData.endsWith("/page/")) "$requestData$apiPage/"
                else requestData.replace(Regex("/page/\\d+/?$"), "/page/$apiPage/")
            }
            requestData.contains("pageNumber=") -> {
                val replaced = requestData.replace(Regex("pageNumber=\\d*"), "pageNumber=$apiPage")
                if (replaced == requestData) {
                    if (requestData.contains("?")) "$requestData&pageNumber=$apiPage"
                    else "$requestData?pageNumber=$apiPage"
                } else replaced
            }
            else -> {
                if (requestData.endsWith("/")) "$requestData$apiPage/"
                else "$requestData/$apiPage/"
            }
        }

        Log.d(name, "🚀 [NETWORK] Fetching Page $page -> URL: $fetchUrl")

        val resp = try {
            withTimeoutOrNull(3000) {
                app.get(fetchUrl).parsedSafe<List<Map<String, Any>>>()
            }
        } catch (_: Exception) {
            null
        }

        val parsed = resp?.mapNotNull { it.toCinemanaItem().toSearchResponse() }
            ?.distinctBy { it.url }
            ?: emptyList()

        if (parsed.isNotEmpty()) {
            val hpList = HomePageList(requestName, parsed)
            injectUrlToHomePageList(hpList, requestData, requestName)
            items.add(hpList)
        }

        val hasMore = parsed.size >= 12
        return@coroutineScope newHomePageResponse(items, hasNext = hasMore)
    }

    private fun injectUrlToHomePageList(hp: HomePageList, url: String, title: String) {
        val candidateFieldNames = listOf("data", "requestData", "request", "pageUrl", "url", "extra", "nextPage", "params", "metadata")
        for (fName in candidateFieldNames) {
            try {
                val f = hp.javaClass.getDeclaredField(fName)
                f.isAccessible = true
                f.set(hp, url)
                return
            } catch (_: Exception) {
            }
        }
    }

    override suspend fun search(query: String): List<SearchResponse>? {
        return search(query, 1)?.items
    }

    override suspend fun search(query: String, page: Int): SearchResponseList? = coroutineScope {
        val encoded = URLEncoder.encode(query, "utf-8")
        val itemsPerPageSearch = 12
        val currentYear = java.util.Calendar.getInstance().get(java.util.Calendar.YEAR)
        val yearRange = "1900,$currentYear"
        val pageParam_0_indexed = (page - 1).coerceAtLeast(0)

        val moviesUrl = "$apiV2/AdvancedSearch?level=0&videoTitle=$encoded&staffTitle=$encoded&year=$yearRange&page=$pageParam_0_indexed&type=movies&itemsPerPage=$itemsPerPageSearch"
        val seriesUrl = "$apiV2/AdvancedSearch?level=0&videoTitle=$encoded&staffTitle=$encoded&year=$yearRange&page=$pageParam_0_indexed&type=series&itemsPerPage=$itemsPerPageSearch"

        val (moviesRawAndParsed, seriesRawAndParsed) = listOf(moviesUrl, seriesUrl).map { url ->
            async(Dispatchers.IO) {
                try {
                    val rawResp = app.get(url).parsedSafe<List<Map<String, Any>>>()
                    val parsedItems = rawResp?.mapNotNull { it.toCinemanaItem().toSearchResponse() } ?: emptyList()
                    Pair(rawResp?.size ?: 0, parsedItems)
                } catch (_: Exception) {
                    Pair(0, emptyList())
                }
            }
        }.awaitAll()

        val movies = moviesRawAndParsed.second
        val series = seriesRawAndParsed.second

        val maxSize = maxOf(movies.size, series.size)
        val interleaved = ArrayList<SearchResponse>(movies.size + series.size)

        for (i in 0 until maxSize) {
            if (i < movies.size) interleaved.add(movies[i])
            if (i < series.size) interleaved.add(series[i])
        }

        fun scoreMatch(title: String?, q: String): Int {
            if (title.isNullOrBlank()) return 0
            val t = title.lowercase()
            val ql = q.lowercase().trim()

            if (t == ql) return 100
            if (t.startsWith(ql)) return 80
            if (t.contains(ql)) return 60

            val tokens = ql.split(Regex("\\s+")).filter { it.isNotBlank() }
            return 40 + tokens.count { t.contains(it) }
        }

        val sorted = interleaved
            .mapIndexed { idx, item -> Triple(item, scoreMatch(item.name ?: item.url ?: "", query), idx) }
            .sortedWith(compareByDescending<Triple<SearchResponse, Int, Int>> { it.second }.thenBy { it.third })
            .map { it.first }

        val finalResults = sorted.distinctBy { "${it.url ?: ""}-${it.name ?: ""}" }
        val hasMore = interleaved.isNotEmpty()

        newSearchResponseList(finalResults, hasMore)
    }

    override suspend fun load(url: String): LoadResponse? {
        val extractedId = url.substringAfterLast("/")
        val detailsUrl = "$mainUrl/api/android/allVideoInfo/id/$extractedId"

        val detailsMap = try {
            app.get(detailsUrl).parsedSafe<Map<String, Any>>()
        } catch (_: Exception) {
            null
        } ?: return null

        val details = detailsMap.toCinemanaItem()

        val title = details.arTitle?.takeIf { it.isNotBlank() } ?: details.enTitle ?: return null
        val posterUrl = details.imgObjUrl
        val plot = details.arContent?.takeIf { it.isNotBlank() } ?: details.enContent
        val year = details.year?.toIntOrNull()

        val ratingFloatPrimary = details.stars?.toFloatOrNull()
        val finalRatingScore: Score? = ratingFloatPrimary?.let { Score.from10(it) } ?: run {
            listOf("rate", "filmRating", "seriesRating").mapNotNull { k ->
                val raw = detailsMap[k]
                when (raw) {
                    is Number -> raw.toDouble().toFloat()
                    is String -> raw.toFloatOrNull()
                    else -> null
                }?.let { Score.from10(it) }
            }.firstOrNull()
        }

        val genresList = details.categories?.mapNotNull { cat ->
            cat.ar_title?.takeIf { it.isNotBlank() } ?: cat.en_title?.takeIf { it.isNotBlank() }
        }?.distinct() ?: emptyList()

        val actorsList: List<ActorData> = details.actorsInfo?.mapNotNull {
            val name = it.name?.trim()?.takeIf { n -> n.isNotEmpty() } ?: return@mapNotNull null
            ActorData(
                Actor(
                    name = name,
                    image = it.staff_img_thumb ?: it.staff_img ?: "defaultImages/not_available.jpg"
                ),
                roleString = null
            )
        } ?: emptyList()

        return if (details.kind == 2) {
            val seasonsAndEpisodesUrl = "$mainUrl/api/android/videoSeason/id/$extractedId"
            val episodesResponse = app.get(seasonsAndEpisodesUrl).parsedSafe<List<Map<String, Any>>>()

            val episodes = mutableListOf<Episode>()
            val seasonsMap = mutableMapOf<Int, MutableList<Episode>>()

            episodesResponse?.forEach { episodeMap ->
                val epDetails = episodeMap.toCinemanaItem()
                if (epDetails.nb != null && (epDetails.enTitle != null || epDetails.arTitle != null)) {
                    val epNum = (epDetails.episodeNummer as? String)?.toIntOrNull() ?: 1
                    val sNum = (epDetails.season as? String)?.toIntOrNull() ?: 1

                    seasonsMap.getOrPut(sNum) { mutableListOf() }.add(
                        newEpisode(epDetails.nb) {
                            this.name = "الموسم $sNum - الحلقة $epNum"
                            this.season = sNum
                            this.episode = epNum
                            this.posterUrl = epDetails.imgObjUrl ?: posterUrl
                            this.description = epDetails.arContent?.takeIf { it.isNotBlank() } ?: epDetails.enContent
                        }
                    )
                }
            }

            seasonsMap.keys.sorted().forEach { sNum ->
                seasonsMap[sNum]?.sortBy { it.episode }
                seasonsMap[sNum]?.let { episodes.addAll(it) }
            }

            newTvSeriesLoadResponse(title, extractedId, TvType.TvSeries, episodes) {
                this.posterUrl = posterUrl
                this.plot = plot
                this.year = year
                this.score = finalRatingScore
                if (genresList.isNotEmpty()) this.tags = genresList
                if (actorsList.isNotEmpty()) this.actors = actorsList
            }
        } else {
            newMovieLoadResponse(title, extractedId, TvType.Movie, extractedId) {
                this.posterUrl = posterUrl
                this.plot = plot
                this.year = year
                this.score = finalRatingScore
                if (genresList.isNotEmpty()) this.tags = genresList
                if (actorsList.isNotEmpty()) this.actors = actorsList
            }
        }
    }

    private fun extractQuality(resolution: String?): Int {
        if (resolution == null) return Qualities.Unknown.value
        val cleanRes = resolution.lowercase().trim()
        return when {
            cleanRes.contains("2160") || cleanRes.contains("4k") -> Qualities.P2160.value
            cleanRes.contains("1440") -> Qualities.P1440.value
            cleanRes.contains("1080") -> Qualities.P1080.value
            cleanRes.contains("720") -> Qualities.P720.value
            cleanRes.contains("480") -> Qualities.P480.value
            cleanRes.contains("360") -> Qualities.P360.value
            cleanRes.contains("240") -> Qualities.P240.value
            else -> Qualities.Unknown.value
        }
    }

    override suspend fun loadLinks(
        data: String,
        isCasting: Boolean,
        subtitleCallback: (SubtitleFile) -> Unit,
        callback: (ExtractorLink) -> Unit
    ): Boolean {
        val extractedId = data.substringAfterLast("/")
        val videosUrl = "$apiV2/transcoddedFiles/id/$extractedId"

        val videoResponse = try {
            app.get(videosUrl).parsedSafe<List<Map<String, Any>>>()
        } catch (_: Exception) {
            null
        }

        if (videoResponse.isNullOrEmpty()) return false

        videoResponse.reversed().forEach { videoMap ->
            val videoUrl = videoMap["videoUrl"] as? String
            val resolution = videoMap["resolution"] as? String

            if (videoUrl != null) {
                callback(
                    newExtractorLink(
                        source = name,
                        name = "",
                        url = videoUrl
                    ) {
                        this.quality = extractQuality(resolution)
                    }
                )
            }
        }

        try {
            app.get("$apiV2/allVideoInfo/id/$extractedId").parsedSafe<Map<String, Any>>()?.let { detailsMap ->
                (detailsMap["translations"] as? List<Map<String, Any>>)?.forEach { sub ->
                    val file = sub["file"] as? String
                    val lang = sub["name"] as? String
                    if (file != null && lang != null) {
                        subtitleCallback(SubtitleFile(lang, file))
                    }
                }
            }
        } catch (_: Exception) {
        }

        return true
    }

    @Serializable
    data class Category(
        val en_title: String? = null,
        val ar_title: String? = null
    )

    @Serializable
    data class ActorInfo(
        val nb: String? = null,
        val name: String? = null,
        val role: String? = null,
        val staff_img: String? = null,
        val staff_img_thumb: String? = null,
        val staff_img_medium_thumb: String? = null
    )

    @Serializable
    data class CinemanaItem(
        val nb: String? = null,
        @SerialName("en_title") val enTitle: String? = null,
        @SerialName("ar_title") val arTitle: String? = null,
        val imgObjUrl: String? = null,
        val year: String? = null,
        @SerialName("en_content") val enContent: String? = null,
        @SerialName("ar_content") val arContent: String? = null,
        val stars: String? = null,
        val kind: Int? = null,
        val fileFile: String? = null,
        @SerialName("episodeNummer") val episodeNummer: String? = null,
        val season: String? = null,
        val categories: List<Category>? = null,
        @SerialName("actorsInfo") val actorsInfo: List<ActorInfo>? = null
    )

    private fun Map<String, Any>.toCinemanaItem(): CinemanaItem {
        val parsedNb = when (val nbValue = this["nb"]) {
            is String -> nbValue
            is Int -> nbValue.toString()
            is Double -> nbValue.toLong().toString()
            is Float -> nbValue.toLong().toString()
            is Number -> nbValue.toLong().toString()
            else -> null
        }

        val parsedKind = when (val k = this["kind"]) {
            is Int -> k
            is String -> k.toIntOrNull()
            is Number -> k.toInt()
            else -> null
        }

        val cats = (this["categories"] as? List<*>)?.mapNotNull {
            (it as? Map<*, *>)?.let { m ->
                Category(
                    en_title = m["en_title"] as? String,
                    ar_title = m["ar_title"] as? String
                )
            }
        }

        val actors = (this["actorsInfo"] as? List<*>)?.mapNotNull {
            (it as? Map<*, *>)?.let { m ->
                ActorInfo(
                    nb = (m["nb"] as? String) ?: (m["nb"] as? Int)?.toString(),
                    name = m["name"] as? String,
                    role = m["role"] as? String,
                    staff_img = m["staff_img"] as? String,
                    staff_img_thumb = m["staff_img_thumb"] as? String
                )
            }
        }

        return CinemanaItem(
            nb = parsedNb,
            enTitle = this["en_title"] as? String,
            arTitle = this["ar_title"] as? String,
            imgObjUrl = this["imgObjUrl"] as? String ?: this["img"] as? String,
            year = this["year"] as? String,
            enContent = this["en_content"] as? String,
            arContent = this["ar_content"] as? String,
            stars = this["stars"] as? String,
            kind = parsedKind,
            fileFile = this["fileFile"] as? String,
            episodeNummer = this["episodeNummer"] as? String,
            season = this["season"] as? String,
            categories = cats,
            actorsInfo = actors
        )
    }

    private fun CinemanaItem.toSearchResponse(): SearchResponse? {
        val validNb = nb ?: return null
        val scoreObject = this.stars?.toFloatOrNull()?.let { Score.from10(it) }
        val finalTitle = arTitle?.takeIf { it.isNotBlank() } ?: enTitle ?: "بدون عنوان"

        return if (kind == 2) {
            newTvSeriesSearchResponse(name = finalTitle, url = validNb, type = TvType.TvSeries) {
                this.posterUrl = imgObjUrl
                this.score = scoreObject
            }
        } else {
            newMovieSearchResponse(name = finalTitle, url = validNb, type = TvType.Movie) {
                this.posterUrl = imgObjUrl
                this.score = scoreObject
            }
        }
    }
}
