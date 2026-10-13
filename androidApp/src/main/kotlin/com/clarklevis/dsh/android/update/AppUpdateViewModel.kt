package com.clarklevis.dsh.android.update

import android.app.Application
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.pm.PackageInfoCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlin.coroutines.coroutineContext

internal data class AndroidRelease(val version: String, val url: String, val size: Long, val digest: String?)
internal data class UpdateState(
    val busy: Boolean = false,
    val status: String? = null,
    val release: AndroidRelease? = null,
    val apk: File? = null
)

internal fun isSkippedVersion(version: String, skipped: String?): Boolean =
    skipped != null && version.removePrefix("v") == skipped.removePrefix("v")

internal fun compareVersions(first: String, second: String): Int {
    fun parts(value: String) = value.removePrefix("v").split('.').map { it.toIntOrNull() ?: 0 }
    val a = parts(first)
    val b = parts(second)
    return (0 until maxOf(a.size, b.size)).firstNotNullOfOrNull { index ->
        (a.getOrElse(index) { 0 }).compareTo(b.getOrElse(index) { 0 }).takeIf { it != 0 }
    } ?: 0
}

internal fun selectAndroidRelease(json: String, installed: String): AndroidRelease? =
    Json.parseToJsonElement(json).jsonArray.mapNotNull { element ->
        val release = element.jsonObject
        if (release["draft"]?.jsonPrimitive?.boolean == true ||
            release["prerelease"]?.jsonPrimitive?.boolean == true) return@mapNotNull null
        val version = release["tag_name"]?.jsonPrimitive?.content ?: return@mapNotNull null
        if (!Regex("v?\\d+\\.\\d+\\.\\d+").matches(version) || compareVersions(version, installed) <= 0) {
            return@mapNotNull null
        }
        val assets = release["assets"]?.jsonArray.orEmpty().map { it.jsonObject }
        // Prefer universal/release APKs; split ABI packages are not independently installable.
        val apk = assets.filter {
            val name = it["name"]!!.jsonPrimitive.content.lowercase()
            name.endsWith(".apk") && !listOf("arm64", "armeabi", "x86", "debug").any(name::contains)
        }.sortedByDescending { it["name"]!!.jsonPrimitive.content.contains("universal", true) }
            .firstOrNull() ?: return@mapNotNull null
        val url = apk["browser_download_url"]!!.jsonPrimitive.content
        if (!url.startsWith("https://github.com/Clarklevis1995/dsh-mobile/releases/download/")) return@mapNotNull null
        AndroidRelease(version, url, apk["size"]!!.jsonPrimitive.long, apk["digest"]?.jsonPrimitive?.contentOrNull)
    }.maxWithOrNull { a, b -> compareVersions(a.version, b.version) }

internal fun selectReleasePageApk(version: String, html: String): AndroidRelease {
    require(Regex("v?\\d+\\.\\d+\\.\\d+").matches(version)) { "无法识别 GitHub 发布版本" }
    val prefix = "/Clarklevis1995/dsh-mobile/releases/download/$version/"
    val paths = Regex("href=\"([^\"]+)\"").findAll(html).map { it.groupValues[1] }
        .filter { path ->
            val name = path.substringAfterLast('/').lowercase()
            path.startsWith(prefix) && name.endsWith(".apk") &&
                !listOf("arm64", "armeabi", "x86", "debug").any(name::contains)
        }.toList()
    val path = paths.sortedByDescending { it.contains("universal", true) }.firstOrNull()
        ?: error("最新正式发布尚未提供可安装的 Android APK，请稍后重试")
    return AndroidRelease(version, "https://github.com$path", -1, null)
}

internal class AppUpdateViewModel(application: Application) : AndroidViewModel(application) {
    private val context = application
    private val client = OkHttpClient.Builder().connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS).callTimeout(10, TimeUnit.MINUTES).build()
    private val mutableState = MutableStateFlow(UpdateState())
    val state = mutableState.asStateFlow()
    @Suppress("DEPRECATION")
    private val installed = context.packageManager.getPackageInfo(context.packageName, 0)
    val currentVersion: String = installed.versionName ?: "未知"

    fun dismiss() { if (!mutableState.value.busy) mutableState.value = UpdateState() }
    fun installationHandled() { mutableState.value = UpdateState() }
    fun reportError(message: String) { mutableState.value = UpdateState(status = message) }

    private val preferences = context.getSharedPreferences("app_updates", Application.MODE_PRIVATE)
    private var startupChecked = false
    private var apiRetryAt = 0L

    fun checkOnStartup() {
        if (startupChecked) return
        startupChecked = true
        performCheck(automatic = true)
    }

    fun skipVersion() {
        val release = mutableState.value.release ?: return
        preferences.edit().putString("skipped_version", release.version.removePrefix("v")).apply()
        dismiss()
    }

    fun check() = performCheck(automatic = false)

    private fun performCheck(automatic: Boolean) = runOperation(silent = automatic) {
        val release = try {
            check(System.currentTimeMillis() >= apiRetryAt) { "GitHub API 暂时限流" }
            val json = client.newCall(Request.Builder()
                .url("https://api.github.com/repos/Clarklevis1995/dsh-mobile/releases?per_page=100")
                .header("Accept", "application/vnd.github+json")
                .header("User-Agent", "DSH-Mobile-Android").build()).execute().use { response ->
                if (response.code == 403 || response.code == 429) {
                    val now = System.currentTimeMillis()
                    apiRetryAt = maxOf(
                        now + (response.header("Retry-After")?.toLongOrNull() ?: 60) * 1000,
                        (response.header("X-RateLimit-Reset")?.toLongOrNull() ?: 0) * 1000
                    )
                }
                check(response.isSuccessful) { "GitHub API 检查失败（${response.code}）" }
                response.body?.string() ?: error("GitHub 返回了空响应")
            }
            selectAndroidRelease(json, currentVersion)
        } catch (exception: CancellationException) {
            throw exception
        } catch (exception: Exception) {
            checkReleasePage()
        }
        val visibleRelease = release?.takeUnless {
            automatic && isSkippedVersion(it.version, preferences.getString("skipped_version", null))
        }
        UpdateState(
            release = visibleRelease,
            status = if (!automatic && release == null) "当前已是最新 Android 版本" else null
        )
    }

    private fun checkReleasePage(): AndroidRelease? {
        val version = client.newCall(Request.Builder()
            .url("https://github.com/Clarklevis1995/dsh-mobile/releases/latest")
            .header("User-Agent", "DSH-Mobile-Android").build()).execute().use { response ->
            check(response.isSuccessful) { "无法访问 GitHub 发布页（${response.code}），请检查网络后重试" }
            val url = response.request.url
            check(url.host == "github.com" && url.encodedPath.startsWith("/Clarklevis1995/dsh-mobile/releases/tag/")) {
                "无法识别 GitHub 最新发布，请稍后重试"
            }
            url.pathSegments.last()
        }
        check(Regex("v?\\d+\\.\\d+\\.\\d+").matches(version)) { "无法识别 GitHub 发布版本" }
        // Verify that the release really contains an Android APK before declaring it up to date.
        val html = client.newCall(Request.Builder()
            .url("https://github.com/Clarklevis1995/dsh-mobile/releases/expanded_assets/$version")
            .header("User-Agent", "DSH-Mobile-Android").build()).execute().use { response ->
            check(response.isSuccessful) { "无法读取 GitHub Android 发布包（${response.code}），请稍后重试" }
            response.body?.string() ?: error("GitHub 发布包列表为空")
        }
        val release = selectReleasePageApk(version, html)
        return release.takeIf { compareVersions(it.version, currentVersion) > 0 }
    }

    fun download(release: AndroidRelease) = runOperation {
        val directory = File(context.cacheDir, "updates").apply { mkdirs() }
        val target = File(directory, "update.apk")
        val partial = File(directory, "update.part")
        try {
            client.newCall(Request.Builder().url(release.url).build()).execute().use { response ->
                check(response.isSuccessful) { "下载失败（${response.code}）" }
                val body = response.body ?: error("下载内容为空")
                val expectedSize = release.size.takeIf { it > 0 } ?: body.contentLength()
                body.byteStream().use { input ->
                    partial.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        var total = 0L
                        while (true) {
                            coroutineContext.ensureActive()
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            check(expectedSize <= 0 || total <= expectedSize) { "安装包大小异常" }
                            output.write(buffer, 0, count)
                            mutableState.value = UpdateState(busy = true, status = if (expectedSize > 0) "正在下载 ${total * 100 / expectedSize}%" else "正在下载 ${total / 1024 / 1024} MB")
                        }
                        check((expectedSize <= 0 || total == expectedSize) && total > 0) { "安装包下载不完整" }
                    }
                }
            }
            release.digest?.takeIf { it.startsWith("sha256:") }?.let { expected ->
                val hash = MessageDigest.getInstance("SHA-256")
                partial.inputStream().use { input ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) { val count = input.read(buffer); if (count < 0) break; hash.update(buffer, 0, count) }
                }
                check(hash.digest().joinToString("") { "%02x".format(it) } == expected.removePrefix("sha256:")) { "安装包校验失败" }
            }
            validateApk(partial)
            target.delete()
            check(partial.renameTo(target)) { "无法保存安装包" }
            UpdateState(apk = target)
        } finally { partial.delete() }
    }

    @Suppress("DEPRECATION")
    private fun validateApk(file: File) {
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val archive = context.packageManager.getPackageArchiveInfo(file.path, flags) ?: error("无效的 APK 安装包")
        check(archive.packageName == context.packageName) { "安装包不属于当前应用" }
        check(PackageInfoCompat.getLongVersionCode(archive) > PackageInfoCompat.getLongVersionCode(installed)) { "安装包构建号未高于当前版本" }
        val current = context.packageManager.getPackageInfo(context.packageName, flags)
        val archiveSignatures = if (Build.VERSION.SDK_INT >= 28) archive.signingInfo?.apkContentsSigners else archive.signatures
        val currentSignatures = if (Build.VERSION.SDK_INT >= 28) current.signingInfo?.apkContentsSigners else current.signatures
        check(!archiveSignatures.isNullOrEmpty() && !currentSignatures.isNullOrEmpty() &&
            archiveSignatures.toSet() == currentSignatures.toSet()) { "安装包签名不一致，无法覆盖安装" }
    }

    private fun runOperation(silent: Boolean = false, operation: suspend () -> UpdateState) {
        if (mutableState.value.busy) return
        mutableState.value = UpdateState(busy = true, status = if (silent) null else "正在检查更新…")
        viewModelScope.launch {
            try { mutableState.value = withContext(Dispatchers.IO) { operation() } }
            catch (exception: CancellationException) { throw exception }
            catch (exception: Exception) { mutableState.value = UpdateState(status = if (silent) null else exception.message ?: "更新失败，请重试") }
        }
    }
}
