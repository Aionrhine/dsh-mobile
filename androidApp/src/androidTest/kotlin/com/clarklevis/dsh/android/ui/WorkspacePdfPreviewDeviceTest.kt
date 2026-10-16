package com.clarklevis.dsh.android.ui

import android.content.res.Configuration
import android.graphics.pdf.PdfDocument
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.core.content.FileProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clarklevis.dsh.android.AndroidWorkspaceLocalFile
import org.junit.Assert.assertTrue
import kotlin.math.abs
import java.util.Locale
import org.junit.Before
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class WorkspacePdfPreviewDeviceTest {
    @get:Rule val compose = createComposeRule()
    private lateinit var originalTestLocale: Locale

    @Before fun useChineseLabels() {
        originalTestLocale = Locale.getDefault()
        Locale.setDefault(Locale.SIMPLIFIED_CHINESE)
    }

    @After fun restoreTestLocale() { Locale.setDefault(originalTestLocale) }


    @Test
    fun pdfScrollsAcrossPagesInBottomSheetAndCloses() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val local = File(context.cacheDir, "workspace-previews/sheet-test/preview-test.pdf")
        local.parentFile?.mkdirs()
        try {
            val document = PdfDocument()
            try {
                repeat(3) { index ->
                    val page = document.startPage(PdfDocument.PageInfo.Builder(300, 500, index + 1).create())
                    page.canvas.drawColor(android.graphics.Color.WHITE)
                    val paint = android.graphics.Paint().apply { textSize = 20f; color = android.graphics.Color.DKGRAY }
                    page.canvas.drawText("PDF page ${index + 1}", 24f, 48f, paint)
                    repeat(18) { line ->
                        paint.textSize = 11f
                        page.canvas.drawText("Document content ${index + 1} - ${line + 1}", 24f, 90f + line * 20f, paint)
                    }
                    document.finishPage(page)
                }
                local.outputStream().use(document::writeTo)
            } finally {
                document.close()
            }
            val file = AndroidWorkspaceLocalFile(local, "s1", "preview-test.pdf", "preview-test.pdf", "application/pdf", "preview")
            // 缓存文件也必须能够交给系统应用打开。
            assertTrue(FileProvider.getUriForFile(context, "${context.packageName}.workspace-files", local).path.orEmpty()
                .contains("workspace_previews"))
            var visible by mutableStateOf(true)
            compose.setContent {
                MaterialTheme {
                    Box(Modifier.fillMaxSize().background(Color(0xFFF5F5F5))) {
                        Text("对话内容")
                        if (visible) WorkspacePdfPreviewSheet(file, onDismiss = { visible = false }, onOpenExternal = {})
                    }
                }
            }
            waitForPdfPage(1)
            assertTrue(compose.onNodeWithTag("workspace-file-preview-sheet").fetchSemanticsNode().boundsInRoot.top > 0f)
            compose.onNodeWithText("1/3").assertIsDisplayed()
            val header = compose.onNodeWithTag("workspace-preview-header").fetchSemanticsNode().boundsInRoot
            val firstPage = compose.onNodeWithContentDescription("第 1 页").fetchSemanticsNode().boundsInRoot
            assertTrue("PDF 应紧贴标题栏下沿", abs(firstPage.top - header.bottom) < 3f)
            assertTrue("PDF 应贴近面板两侧", firstPage.width > header.width * 0.98f)
            compose.onNodeWithText("另存为").assertDoesNotExist()
            compose.onNodeWithText("第 1 页 / 3").assertDoesNotExist()
            screenshot("preview-sheet-pdf-first.png")
            val pages = compose.onNodeWithTag("workspace-pdf-pages")
            pages.performTouchInput { swipeUp(durationMillis = 600) }
            compose.waitUntil(10_000) {
                pages.fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange].value() > 0f
            }
            pages.performScrollToIndex(2)
            waitForPdfPage(3)
            compose.onNodeWithText("3/3").assertIsDisplayed()
            compose.onNodeWithText("preview-test.pdf").assertIsDisplayed()
            screenshot("preview-sheet-pdf-last.png")
            pages.performScrollToIndex(0)
            waitForPdfPage(1)
            compose.onNodeWithContentDescription("关闭文件预览").performClick()
            compose.onNodeWithTag("workspace-file-preview-sheet").assertDoesNotExist()
        } finally {
            local.delete()
            local.parentFile?.delete()
        }
    }

    @Test
    fun multilineTitleIsCenteredAndSaveMenuKeepsPreviewOpen() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val name = "2026年国庆海南三亚旅游攻略与详细行程安排（含每日行程、交通住宿及餐饮预算、景点预约和亲子出行注意事项）.pdf"
        val file = AndroidWorkspaceLocalFile(File(context.cacheDir, name), "s1", name, name, "application/pdf", "preview")
        var saveCount = 0
        compose.setContent {
            MaterialTheme {
                WorkspaceFilePreviewSheet(file, onDismiss = {}, onSave = { saveCount++ }) { Text("文件内容") }
            }
        }
        val title = compose.onNodeWithTag("workspace-preview-title")
        val layout = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
        title.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layout) }
        assertTrue("长文件名应完整换行", layout.single().lineCount > 1 && !layout.single().hasVisualOverflow)
        val titleBounds = title.fetchSemanticsNode().boundsInRoot
        val headerBounds = compose.onNodeWithTag("workspace-preview-header").fetchSemanticsNode().boundsInRoot
        assertTrue("文件名应位于标题栏正中", abs(titleBounds.center.x - headerBounds.center.x) < 2f)
        compose.onNodeWithContentDescription("关闭文件预览").assertIsDisplayed()
        compose.onNodeWithContentDescription("文件菜单").performClick()
        compose.onNodeWithText("保存").assertIsDisplayed()
        compose.onNodeWithText("另存为").assertDoesNotExist()
        compose.onNodeWithText("使用其他应用打开").assertDoesNotExist()
        screenshot("preview-sheet-menu.png")
        compose.onNodeWithText("保存").performClick()
        compose.runOnIdle { assertTrue("保存只触发一次", saveCount == 1) }
        compose.onNodeWithTag("workspace-file-preview-sheet").assertIsDisplayed()
        compose.onNodeWithText("保存").assertDoesNotExist()
    }

    @Test
    fun directoryUsesCircleBackButtonAndHidesItAtRoot() {
        var path by mutableStateOf("build/reports")
        var backCount = 0
        var doneCount = 0
        compose.setContent {
            MaterialTheme {
                WorkspaceFileSheetHeader(
                    path = path,
                    onBack = { backCount++; path = path.substringBeforeLast('/', ".") },
                    onDismiss = { doneCount++ }
                )
            }
        }
        val back = compose.onNodeWithTag("workspace-files-back")
        val bounds = back.fetchSemanticsNode().boundsInRoot
        assertTrue("返回按钮应为正方形圆形容器", abs(bounds.width - bounds.height) < 1f)
        compose.onNodeWithText("‹ 上一级").assertDoesNotExist()
        compose.onNodeWithContentDescription("上一级").performClick()
        compose.onNodeWithText("build").assertIsDisplayed()
        screenshot("workspace-files-back.png")
        compose.onNodeWithContentDescription("上一级").performClick()
        back.assertDoesNotExist()
        compose.onNodeWithText("工作区根目录").assertIsDisplayed()
        compose.onNodeWithText("完成").performClick()
        compose.runOnIdle { assertTrue(backCount == 2 && doneCount == 1) }
    }

    @Test
    fun longCodeScrollsInsideDarkBottomSheetWithoutMovingToolbar() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val local = File(context.cacheDir, "preview-sheet-test.kt")
        try {
            local.writeText((1..300).joinToString("\n") { "val line$it = \"Preview line $it\"" })
            val file = AndroidWorkspaceLocalFile(local, "s1", local.name, local.name, "text/x-kotlin", "preview")
            var visible by mutableStateOf(true)
            compose.setContent {
                val configuration = Configuration(LocalConfiguration.current).apply {
                    uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or Configuration.UI_MODE_NIGHT_YES
                }
                CompositionLocalProvider(LocalConfiguration provides configuration) {
                    MaterialTheme(colorScheme = darkColorScheme()) {
                        Box(Modifier.fillMaxSize().background(Color(0xFF101010))) {
                            Text("对话内容")
                            if (visible) WorkspaceCodePreviewSheet(file, { visible = false }, {})
                        }
                    }
                }
            }
            compose.waitUntil(15_000) { compose.onAllNodesWithTag("workspace-code-content").fetchSemanticsNodes().isNotEmpty() }
            val content = compose.onNodeWithTag("workspace-code-content")
            val sheetTop = compose.onNodeWithTag("workspace-file-preview-sheet").fetchSemanticsNode().boundsInRoot.top
            content.performTouchInput { swipeUp(durationMillis = 600) }
            compose.waitUntil(10_000) {
                content.fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange].value() > 0f
            }
            assertTrue(compose.onNodeWithTag("workspace-file-preview-sheet").fetchSemanticsNode().boundsInRoot.top == sheetTop)
            compose.onNodeWithText(local.name).assertIsDisplayed()
            val pixels = compose.onNodeWithTag("workspace-code-document").captureToImage().toPixelMap()
            assertTrue("深色模式的代码正文应保持深色背景", pixels[2, 2].luminance() < 0.2f)
            screenshot("preview-sheet-code-dark.png")
            compose.onNodeWithContentDescription("关闭文件预览").performClick()
            compose.onNodeWithTag("workspace-file-preview-sheet").assertDoesNotExist()
        } finally {
            local.delete()
        }
    }

    @Test
    fun previewCanBeDismissedByDraggingDown() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = AndroidWorkspaceLocalFile(
            File(context.cacheDir, "gesture-test.txt"), "s1", "gesture-test.txt",
            "gesture-test.txt", "text/plain", "preview"
        )
        var visible by mutableStateOf(true)
        var dismissCount = 0
        compose.setContent {
            MaterialTheme {
                if (visible) WorkspaceFilePreviewSheet(file, { dismissCount++; visible = false }) { Text("文件内容") }
            }
        }
        compose.onNodeWithTag("workspace-file-preview-sheet").performTouchInput { swipeDown(durationMillis = 500) }
        compose.onNodeWithTag("workspace-file-preview-sheet").assertDoesNotExist()
        compose.runOnIdle { assertTrue("下拉只触发一次关闭", dismissCount == 1) }
    }

    @Test
    fun closeButtonSlidesSheetDownBeforeRemovingPreview() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = AndroidWorkspaceLocalFile(
            File(context.cacheDir, "animation-test.txt"), "s1", "animation-test.txt",
            "animation-test.txt", "text/plain", "preview"
        )
        var visible by mutableStateOf(true)
        var dismissCount = 0
        compose.setContent {
            MaterialTheme {
                if (visible) WorkspaceFilePreviewSheet(
                    file = file,
                    onDismiss = { dismissCount++; visible = false }
                ) { Text("文件内容") }
            }
        }
        compose.waitForIdle()
        val sheet = compose.onNodeWithTag("workspace-file-preview-sheet")
        val expandedTop = sheet.fetchSemanticsNode().boundsInRoot.top
        compose.mainClock.autoAdvance = false
        try {
            compose.onNodeWithContentDescription("关闭文件预览").performClick()
            compose.runOnIdle { assertTrue("关闭时应保留弹层以播放动画", dismissCount == 0) }
            compose.mainClock.advanceTimeBy(64)
            compose.waitForIdle()
            sheet.assertExists()
            assertTrue("退出过程中面板应向下移动", sheet.fetchSemanticsNode().boundsInRoot.top > expandedTop)
            compose.runOnIdle { assertTrue("动画未结束时不应移除弹层", dismissCount == 0) }
            compose.mainClock.advanceTimeBy(1_000)
            compose.waitForIdle()
            sheet.assertDoesNotExist()
            compose.runOnIdle { assertTrue("动画完成后只关闭一次", dismissCount == 1) }
        } finally {
            compose.mainClock.autoAdvance = true
        }
    }

    private fun waitForPdfPage(page: Int) {
        try {
            compose.waitUntil(15_000) { compose.onAllNodesWithContentDescription("第 $page 页").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithContentDescription("第 $page 页").assertIsDisplayed()
        } catch (failure: Throwable) {
            screenshot("preview-sheet-failure.png")
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            File(context.cacheDir, "preview-sheet-failure.txt").writeText(
                compose.onNodeWithTag("workspace-file-preview-sheet").printToString()
            )
            throw failure
        }
    }

    private fun screenshot(name: String) {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = instrumentation.uiAutomation.takeScreenshot()
        File(instrumentation.targetContext.cacheDir, name).outputStream().use {
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
        }
        bitmap.recycle()
    }
}
