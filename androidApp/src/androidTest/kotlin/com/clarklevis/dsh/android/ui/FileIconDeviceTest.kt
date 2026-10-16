package com.clarklevis.dsh.android.ui

import android.graphics.Bitmap
import android.content.res.Configuration
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clarklevis.dsh.shared.facade.FileIconKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FileIconDeviceTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun everyVectorRendersWithItsOriginalBodyColor() {
        compose.setContent {
            MaterialTheme {
                Column(Modifier.testTag("all-icons")) {
                    FileIconKind.entries.chunked(8).forEach { row ->
                        Row {
                            row.forEach { kind ->
                                FileTypeIcon(kind, Modifier.size(32.dp).testTag(kind.assetKey))
                            }
                        }
                    }
                }
            }
        }
        FileIconKind.entries.forEach { kind ->
            val pixels = compose.onNodeWithTag(kind.assetKey).captureToImage().toPixelMap()
            val body = pixels[pixels.width / 4, pixels.height / 4]
            assertColor(kind.colorRgb, body)
            assertTrue("${kind.assetKey} must retain white format marks", (pixels.width / 5 until pixels.width * 4 / 5).any { x ->
                (pixels.height / 2 until pixels.height * 17 / 20).any { y ->
                    val color = pixels[x, y]
                    color.alpha > 0.95f && color.red > 0.95f && color.green > 0.95f && color.blue > 0.95f
                }
            })
        }
        saveImage("all-icons", "file-icons-grid.png")
    }

    @Test fun lightCardRetainsTintAndClickAction() = checkCard(dark = false)
    @Test fun darkCardRetainsTintAndClickAction() = checkCard(dark = true)

    private fun checkCard(dark: Boolean) {
        var clicks = 0
        val longName = "旅行攻略完整版_".repeat(8) + ".pdf"
        val longSummary = "保留简短说明与页数，超过最大宽度后自动换行。".repeat(3)
        compose.setContent {
            val config = Configuration(LocalConfiguration.current).apply {
                uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                    if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
            }
            CompositionLocalProvider(LocalConfiguration provides config) {
                MaterialTheme(colorScheme = if (dark) darkColorScheme() else lightColorScheme()) {
                    Column(
                        Modifier.fillMaxWidth().padding(16.dp).testTag("cards"),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                        horizontalAlignment = Alignment.End
                    ) {
                        FileReferenceCard(
                            "报告.PDF", { clicks++ }, Modifier.testTag("card"),
                            description = "2026 国庆海南三亚旅游攻略 · A4 共 8 页（天气/交通/住宿/7 日行程/门票预约/美食/免税避坑）"
                        )
                        FileReferenceCard("FilePreview.kt", {}, Modifier.testTag("short-card"))
                        FileReferenceCard("附件.unknown", {})
                        FileReferenceCard(longName, {}, Modifier.testTag("long-card"), description = longSummary)
                    }
                }
            }
        }
        compose.onNodeWithText("报告.PDF").assertIsDisplayed()
        compose.onNodeWithText("2026 国庆海南三亚旅游攻略 · A4 共 8 页").assertIsDisplayed()
        compose.onNodeWithText("天气/交通", substring = true).assertDoesNotExist()
        val parent = compose.onNodeWithTag("cards").fetchSemanticsNode().boundsInRoot
        val short = compose.onNodeWithTag("short-card").fetchSemanticsNode().boundsInRoot
        val long = compose.onNodeWithTag("long-card").fetchSemanticsNode().boundsInRoot
        assertTrue("短内容不应撑满卡片最大宽度", short.width < long.width)
        assertTrue("卡片不能超过最大宽度", long.width / compose.density.density <= 320.5f)
        assertEquals(parent.right, short.right, 1f)
        assertEquals(parent.right, long.right, 1f)
        for (value in listOf(longName, longSummary)) {
            val layouts = mutableListOf<TextLayoutResult>()
            compose.onNodeWithText(value, useUnmergedTree = true)
                .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            assertTrue("文件名和说明应自动换行", layouts.single().lineCount > 1)
        }
        val pixels = compose.onNodeWithTag("card").captureToImage().toPixelMap()
        assertColor(FileIconKind.PDF.cardBackgroundRgb(dark), pixels[pixels.width / 2, 2])
        compose.onNodeWithText("FilePreview.kt").assertIsDisplayed()
        compose.onNodeWithText("附件.unknown").assertIsDisplayed()
        val title = compose.onNodeWithText("FilePreview.kt", useUnmergedTree = true).captureToImage().toPixelMap()
        assertTrue("文件名应使用主题前景色", (0 until title.width).any { x ->
            (0 until title.height).any { y ->
                val pixel = title[x, y]
                if (dark) pixel.red > 0.8f && pixel.green > 0.8f && pixel.blue > 0.8f
                else pixel.red < 0.2f && pixel.green < 0.2f && pixel.blue < 0.2f
            }
        })
        saveImage("cards", "file-cards-${if (dark) "dark" else "light"}.png")
        // 先验证静止配色，再验证点击，避免将按压涟漪误判为背景色。
        compose.onNodeWithText("报告.PDF").performClick()
        compose.runOnIdle { assertEquals(1, clicks) }
    }

    private fun saveImage(tag: String, name: String) {
        val image = compose.onNodeWithTag(tag).captureToImage().asAndroidBitmap()
        val file = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir.resolve(name)
        file.outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private fun assertColor(rgb: Int, actual: Color) {
        assertEquals(((rgb shr 16) and 255) / 255f, actual.red, 0.015f)
        assertEquals(((rgb shr 8) and 255) / 255f, actual.green, 0.015f)
        assertEquals((rgb and 255) / 255f, actual.blue, 0.015f)
    }
}
