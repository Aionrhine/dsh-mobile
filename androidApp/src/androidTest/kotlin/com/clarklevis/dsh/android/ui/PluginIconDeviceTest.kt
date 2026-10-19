package com.clarklevis.dsh.android.ui

import android.graphics.Bitmap
import android.graphics.Color
import android.content.res.Configuration
import android.util.Base64
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.ByteArrayOutputStream

class PluginIconDeviceTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val blueSVG get() = svgURL("<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64'><circle cx='32' cy='32' r='28' fill='#2e6be6'/></svg>")

    @Test fun concurrentRequestsShareRenderedPixelsAndSurviveCancelledWaiters() = runBlocking {
        val cache = PluginIconImageCache(context.assets)
        val source = blueSVG
        val cancelled = async(start = CoroutineStart.UNDISPATCHED) { cache.load(source, "shell") }
        cancelled.cancel()
        val results = (1..24).map { async { cache.load(source, "plugin-$it") } }.awaitAll()
        val image = requireNotNull(results.first())
        results.forEach { assertSame("相同 SVG 只能解码一次", image, it) }
        assertSame(image, cache.load(source, "other-plugin"))
        assertEquals(0, Color.alpha(image.getPixel(0, 0)))
        val center = image.getPixel(image.width / 2, image.height / 2)
        assertTrue(Color.blue(center) > Color.red(center) + 80)
        assertEquals(255, Color.alpha(center))
    }

    @Test fun assetsAndMalformedImagesUseCachedFallbacks() = runBlocking {
        val cache = PluginIconImageCache(context.assets)
        val images = listOf("shell", "agent-loop", "subagent", "web-search", "default").map { name ->
            val image = requireNotNull(cache.load(null, name))
            assertSame(image, cache.load(null, name))
            val pixels = IntArray(image.width * image.height)
            image.getPixels(pixels, 0, image.width, 0, 0, image.width, image.height)
            assertTrue("$name 不能是空白图片", pixels.count { Color.alpha(it) > 100 } > 100)
            image
        }
        assertEquals(5, images.toSet().size)
        for (invalid in listOf("bad", "data:image/png;base64,???", svgURL("invalid"), "x".repeat(256_000))) {
            assertSame(images.first(), cache.load(invalid, "shell"))
        }
        assertSame(images.last(), cache.load(null, "unknown-plugin"))
    }

    @Test fun bitmapAndSvgKeepAspectRatioAtIconResolution() = runBlocking {
        val cache = PluginIconImageCache(context.assets)
        val original = Bitmap.createBitmap(2048, 1024, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.RED) }
        val bytes = ByteArrayOutputStream().use { output ->
            original.compress(Bitmap.CompressFormat.PNG, 100, output)
            output.toByteArray()
        }
        original.recycle()
        val bitmap = requireNotNull(cache.load("data:image/png;base64," + Base64.encodeToString(bytes, Base64.NO_WRAP), "shell"))
        assertTrue(bitmap.width <= 256 && bitmap.height <= 256)
        assertEquals(2f, bitmap.width.toFloat() / bitmap.height, 0.01f)
        assertEquals(Color.RED, bitmap.getPixel(bitmap.width / 2, bitmap.height / 2))
        val wide = requireNotNull(cache.load(svgURL("<svg xmlns='http://www.w3.org/2000/svg' width='64' height='32'><rect width='64' height='32' fill='#ff0000'/></svg>"), "shell"))
        assertEquals(Color.RED, wide.getPixel(128, 128))
        assertEquals(0, Color.alpha(wide.getPixel(128, 0)))
    }

    @Test fun scrollingIconsNeverCreatesWebViews() {
        var root: View? = null
        val source = blueSVG
        compose.setContent {
            MaterialTheme {
                val view = LocalView.current
                SideEffect { root = view.rootView }
                LazyColumn(Modifier.fillMaxSize().testTag("plugin-icon-list")) {
                    items(48) { index ->
                        Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            PluginIcon(source, "plugin-$index", Modifier.size(48.dp).testTag("icon-$index"))
                            Text("插件 $index", Modifier.padding(start = 12.dp))
                        }
                    }
                }
            }
        }
        fun check(index: Int) {
            compose.waitUntil(10_000) {
                val pixels = compose.onNodeWithTag("icon-$index").captureToImage().toPixelMap()
                val center = pixels[pixels.width / 2, pixels.height / 2]
                center.blue > center.red + 0.3f
            }
            compose.runOnIdle { assertEquals("滚动列表中不应创建网页视图", 0, webViewCount(requireNotNull(root))) }
        }
        check(0)
        compose.onNodeWithTag("plugin-icon-list").performScrollToIndex(47)
        check(47)
        compose.onNodeWithTag("plugin-icon-list").performScrollToIndex(0)
        check(0)
    }

    @Test fun nativeArtworkInLightMode() = artworkGallery(dark = false)
    @Test fun nativeArtworkInDarkMode() = artworkGallery(dark = true)

    private fun artworkGallery(dark: Boolean) {
        compose.setContent {
            val config = Configuration(LocalConfiguration.current).apply {
                uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                    if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
            }
            CompositionLocalProvider(LocalConfiguration provides config) {
                MaterialTheme(colorScheme = if (dark) darkColorScheme() else lightColorScheme()) {
                    Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface).padding(20.dp).testTag("gallery"),
                        verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        for (name in listOf("shell", "agent-loop", "subagent", "web-search", "default")) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                PluginIcon(null, name, Modifier.size(60.dp).testTag(name))
                                Text(name, Modifier.padding(start = 16.dp), color = MaterialTheme.colorScheme.onSurface)
                            }
                        }
                    }
                }
            }
        }
        // 等待共享后台解码完成，截图必须包含实际的渐变图标。
        compose.waitUntil(10_000) {
            val pixels = compose.onNodeWithTag("default").captureToImage().toPixelMap()
            (pixels.height / 3 until pixels.height * 2 / 3).any { y ->
                (pixels.width / 3 until pixels.width * 2 / 3).any { x ->
                    val pixel = pixels[x, y]
                    pixel.blue > pixel.red + 0.1f
                }
            }
        }
        val image = compose.onNodeWithTag("gallery").captureToImage().asAndroidBitmap()
        context.cacheDir.resolve("plugin-icons-${if (dark) "dark" else "light"}.png").outputStream().use {
            image.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }

    private fun webViewCount(view: View): Int = (if (view is WebView) 1 else 0) +
        if (view is ViewGroup) (0 until view.childCount).sumOf { webViewCount(view.getChildAt(it)) } else 0

    private fun svgURL(svg: String) = "data:image/svg+xml;base64," + Base64.encodeToString(svg.toByteArray(), Base64.NO_WRAP)
}
