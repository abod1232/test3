// ملف: VideolandExtractor.kt
package com.arabseed

import android.util.Log
import com.lagradost.cloudstream3.SubtitleFile
import com.lagradost.cloudstream3.app
import com.lagradost.cloudstream3.utils.*

class VideolandExtractor : ExtractorApi() {
    override var name = "Videoland"
    override var mainUrl = "https://videoland.sbs"
    override val requiresReferer = true

    override suspend fun getUrl(
        url: String,
        referer: String?,
        subtitleCallback: (SubtitleFile) -> Unit,
        callback: (ExtractorLink) -> Unit
    ) {
        try {
            Log.d(name, "Step 1: Fetching page -> $url")
            
            // 1. تحميل الصفحة الأصلية
            val response = app.get(url, referer = referer ?: mainUrl).text

            // 2. فك تشفير الجافاسكربت تلقائياً باستخدام JsUnpacker المدمج في Cloudstream
            val unpackedHtml = JsUnpacker(response).unpack() ?: response

            // 3. التعبير النمطي لاستخراج رابط master.m3u8 أو master.txt مع المتغيرات (Tokens)
            val regex = Regex("""https://[^"']+?/hls\d+/[^"']+?/master\.(?:txt|m3u8)(?:\?[^"']*)?""")
            
            val matches = regex.findAll(unpackedHtml).toList()
            
            if (matches.isEmpty()) {
                Log.w(name, "No media links found in unpacked HTML")
                return
            }

            // 4. المرور على الروابط المستخرجة وإضافتها
            matches.forEach { match ->
                val link = match.value
                Log.d(name, "Found media link: $link")
                
                // تحديد نوع الملف (عادة كلا الامتدادين يعملان كـ M3U8)
                val isM3u8 = link.contains(".m3u8") || link.contains(".txt")

                callback.invoke(
                    ExtractorLink(
                        source = this.name,
                        name = this.name,
                        url = link,
                        referer = "https://videoland.sbs/",
                        quality = Qualities.Unknown.value,
                        type = if (isM3u8) ExtractorLinkType.M3U8 else ExtractorLinkType.VIDEO,
                        
                        // 5. تمرير الهيدرات المهمة لتخطي الحماية
                        headers = mapOf(
                            "sec-ch-ua-platform" to "\"Android\"",
                            "sec-ch-ua" to "\"Chromium\";v=\"148\", \"Google Chrome\";v=\"148\", \"Not/A)Brand\";v=\"99\"",
                            "sec-ch-ua-mobile" to "?1",
                            "accept" to "*/*",
                            "origin" to "https://videoland.sbs",
                            "sec-fetch-site" to "cross-site",
                            "sec-fetch-mode" to "cors",
                            "sec-fetch-dest" to "empty"
                        )
                    )
                )
            }
        } catch (e: Exception) {
            Log.e(name, "Error in Videoland extractor", e)
        }
    }
}
