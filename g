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

companion object {
    const val TAG = "MyCima"
    var redirectUrl: String? = null
}
