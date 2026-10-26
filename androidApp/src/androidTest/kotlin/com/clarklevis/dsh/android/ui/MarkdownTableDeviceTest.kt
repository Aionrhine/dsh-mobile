package com.clarklevis.dsh.android.ui

import android.content.ClipboardManager
import android.content.Context
import android.view.View
import android.view.ViewGroup
import android.widget.HorizontalScrollView
import android.widget.TableLayout
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Modifier
import androidx.activity.compose.setContent
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.platform.app.InstrumentationRegistry
import com.clarklevis.dsh.shared.facade.MarkdownTableExport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class MarkdownTableDeviceTest {
    @get:Rule val locale = ChineseDeviceLocaleRule()
    @get:Rule val compose = createComposeRule()

    @Test fun tenColumnsKeepReadableWidthsAndCopyAndFullscreenWork() {
        var root: View? = null
        val header = listOf("编号", "任务名称", "负责人", "所属部门", "优先级", "开始日期", "截止日期", "进度状态", "主要交付物", "备注说明")
        val values = listOf("001", "**新版官网首页改版**", "王晓明", "设计部", "高", "2026-10-21", "2026-11-05", "进行中", "`design.pdf`", "需与前端确认动效成本，支持深色模式")
        val source = "前文\n\n|${header.joinToString("|")}|\n|${header.joinToString("|") { "---" }}|\n|${values.joinToString("|")}|\n\n后文"
        compose.setContent {
            root = LocalView.current
            DshTheme { Column(Modifier.verticalScroll(rememberScrollState())) { DshMarkdownText(source) } }
        }
        compose.onNodeWithTag("markdown-table-card").assertIsDisplayed()
        val table = compose.runOnIdle { descendants(checkNotNull(root)).filterIsInstance<TableLayout>().single() }
        compose.runOnIdle {
            val row = table.getChildAt(0) as ViewGroup
            val minimum = 95 * table.resources.displayMetrics.density
            assertEquals(10, row.childCount)
            repeat(10) { assertTrue("第 $it 列不应被压成竖排", row.getChildAt(it).width >= minimum) }
            assertTrue(table.width > checkNotNull(root).width * 2)
            assertEquals(2, table.childCount)
        }
        androidx.test.espresso.Espresso.onView(org.hamcrest.Matchers.instanceOf(HorizontalScrollView::class.java))
            .perform(androidx.test.espresso.action.ViewActions.swipeLeft())
        compose.runOnIdle {
            assertTrue("横向拖动应滚动表格", (table.parent as HorizontalScrollView).scrollX > 0)
        }
        compose.onNodeWithContentDescription("复制表格").performClick()
        val clipboard = InstrumentationRegistry.getInstrumentation().targetContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        compose.runOnIdle {
            val plain = clipboard.primaryClip?.getItemAt(0)?.text.toString()
            assertTrue(plain.contains("新版官网首页改版"))
            assertTrue(plain.contains("design.pdf"))
            assertFalse(plain.contains("**")); assertFalse(plain.contains("`")); assertFalse(plain.contains("---"))
            assertEquals(10, plain.lineSequence().first().split('\t').size)
        }
        compose.onNodeWithContentDescription("全屏浏览表格").performClick()
        compose.onNodeWithTag("markdown-table-fullscreen").assertIsDisplayed()
        android.os.SystemClock.sleep(4000)
        // 保存真实渲染，检查表格宽度、工具栏与同一行单元格的高度。
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        InstrumentationRegistry.getInstrumentation().targetContext.cacheDir.resolve("markdown-table-fullscreen.png").outputStream().use {
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
        }
        bitmap.recycle()
        val downloads = compose.onAllNodes(androidx.compose.ui.test.hasContentDescription("下载 CSV"))
        downloads[downloads.fetchSemanticsNodes().lastIndex].performClick()
        android.os.SystemClock.sleep(1000)
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        // 第一次返回可能只关闭文件名输入键盘，只有选择器仍在前台时才继续取消。
        repeat(3) {
            if (automation.rootInActiveWindow?.packageName?.toString()?.contains("documentsui") == true) {
                val time = android.os.SystemClock.uptimeMillis()
                automation.injectInputEvent(android.view.KeyEvent(time, time, android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.KEYCODE_BACK, 0), true)
                automation.injectInputEvent(android.view.KeyEvent(time, time + 20, android.view.KeyEvent.ACTION_UP, android.view.KeyEvent.KEYCODE_BACK, 0), true)
                android.os.SystemClock.sleep(700)
            }
        }
        assertEquals("选择器取消后应回到应用", "com.clarklevis.dsh.android", automation.rootInActiveWindow?.packageName?.toString())
        compose.onNodeWithTag("markdown-table-fullscreen").assertIsDisplayed()
        androidx.test.espresso.Espresso.pressBack()
        compose.onNodeWithTag("markdown-table-fullscreen").assertDoesNotExist()
        compose.onNodeWithTag("markdown-table-card").assertIsDisplayed()
        compose.runOnIdle { ((table.getChildAt(0) as ViewGroup).getChildAt(0)).performLongClick() }
        compose.onNodeWithText("选择文字").performClick()
        compose.onNodeWithTag("markdown-selection-page").assertIsDisplayed()
    }

    @Test fun fullscreenSurvivesRotationAndMatchesDocumentHeaderInDarkMode() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val preferences = context.getSharedPreferences("table-rotation-test", Context.MODE_PRIVATE)
        val appearance = AppearanceSettings(preferences).apply { selectInterfaceStyle(InterfaceStyle.DARK) }
        var activity: androidx.activity.ComponentActivity? = null
        val source = "| 品牌 | 强项 | 弱项 | 参考 |\n| --- | --- | --- | --- |\n" +
            (1..8).joinToString("\n") { "| 品牌$it | 信号稳定、系统流畅，支持多设备协同 | 需确认价格与续航表现 | 测试资料 |" }
        val content: @androidx.compose.runtime.Composable () -> Unit = {
            var host = androidx.compose.ui.platform.LocalContext.current
            while (host is android.content.ContextWrapper && host !is androidx.activity.ComponentActivity) host = host.baseContext
            activity = host as androidx.activity.ComponentActivity
            DshTheme(appearance) {
                Column(Modifier.verticalScroll(rememberScrollState())) { DshMarkdownText(source) }
            }
        }
        compose.setContent(content)
        val application = checkNotNull(activity).application
        val initialOrientation = checkNotNull(activity).requestedOrientation
        val callback = object : android.app.Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(next: android.app.Activity, state: android.os.Bundle?) {
                if (next is androidx.activity.ComponentActivity && next.javaClass == activity?.javaClass) {
                    java.util.Locale.setDefault(java.util.Locale.SIMPLIFIED_CHINESE)
                    next.setContent(content = content)
                }
            }
            override fun onActivityStarted(next: android.app.Activity) {}
            override fun onActivityResumed(next: android.app.Activity) {}
            override fun onActivityPaused(next: android.app.Activity) {}
            override fun onActivityStopped(next: android.app.Activity) {}
            override fun onActivitySaveInstanceState(next: android.app.Activity, state: android.os.Bundle) {}
            override fun onActivityDestroyed(next: android.app.Activity) {}
        }
        application.registerActivityLifecycleCallbacks(callback)
        fun screenshot(name: String) {
            compose.waitForIdle()
            val titleBounds = compose.onNodeWithTag("document-page-title").fetchSemanticsNode().boundsInRoot
            val pageBounds = compose.onNodeWithTag("markdown-table-fullscreen").fetchSemanticsNode().boundsInRoot
            assertEquals("横竖屏标题必须始终居中", pageBounds.center.x, titleBounds.center.x, 2f)
            android.os.SystemClock.sleep(500)
            val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
            context.cacheDir.resolve("$name.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
            val gutter = bitmap.getPixel((10 * context.resources.displayMetrics.density).toInt(), bitmap.height / 2)
            assertEquals("预览页边距必须跟随应用深浅模式", if (name.contains("-dark-")) android.graphics.Color.BLACK else android.graphics.Color.WHITE, gutter)
            bitmap.recycle()
        }
        try {
            compose.onNodeWithContentDescription("全屏浏览表格").performClick()
            compose.onNodeWithTag("markdown-table-fullscreen").assertIsDisplayed()
            val title = compose.onNodeWithTag("document-page-title").fetchSemanticsNode().boundsInRoot
            val page = compose.onNodeWithTag("markdown-table-fullscreen").fetchSemanticsNode().boundsInRoot
            assertEquals(page.center.x, title.center.x, 2f)
            compose.onNodeWithTag("markdown-table-close").assertIsDisplayed()
            screenshot("table-page-android-dark-portrait")
            compose.runOnIdle { appearance.selectInterfaceStyle(InterfaceStyle.LIGHT) }
            screenshot("table-page-android-light-portrait")
            compose.onNodeWithContentDescription("旋转屏幕").performClick()
            compose.waitUntil(10_000) {
                val metrics = activity?.resources?.configuration
                metrics != null && metrics.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
            }
            compose.onNodeWithTag("markdown-table-fullscreen").assertIsDisplayed()
            screenshot("table-page-android-light-landscape")
            compose.runOnIdle { appearance.selectInterfaceStyle(InterfaceStyle.DARK) }
            screenshot("table-page-android-dark-landscape")
            compose.onNodeWithContentDescription("旋转屏幕").performClick()
            compose.waitUntil(10_000) {
                activity?.resources?.configuration?.orientation == android.content.res.Configuration.ORIENTATION_PORTRAIT
            }
            compose.onNodeWithTag("markdown-table-fullscreen").assertIsDisplayed()
            // 再次进入横屏后关闭，验证页面退出会还原进入预览前的方向策略。
            compose.onNodeWithContentDescription("旋转屏幕").performClick()
            compose.waitUntil(10_000) {
                activity?.resources?.configuration?.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
            }
            compose.onNodeWithTag("markdown-table-close").performClick()
            compose.onNodeWithTag("markdown-table-fullscreen").assertDoesNotExist()
            compose.waitUntil(10_000) {
                activity?.requestedOrientation == initialOrientation
            }
        } finally {
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                activity?.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            }
            android.os.SystemClock.sleep(500)
            application.unregisterActivityLifecycleCallbacks(callback)
            preferences.edit().clear().apply()
        }
    }

    @Test fun tableMarkersKeepRichCellsAndRespectCodeFencesAndAdjacentTables() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        compose.runOnIdle {
            val markwon = buildDshMarkwon(context, dshTestPalette(), interactiveTables = true)
            val code = markwon.toMarkdown("```md\n| a | b |\n| --- | --- |\n| x | y |\n```")
            assertTrue(code.getSpans(0, code.length, DshTableMarker::class.java).isEmpty())
            val rendered = markwon.toMarkdown("说明\n| 名称 | 值 |\n| --- | ---: |\n| **粗体** | [链接](https://example.com) |\n\n之后\n\n| a | b |\n| --- | --- |\n| 转义\\|竖线 | `x,y` |")
            val tables = rendered.getSpans(0, rendered.length, DshTableMarker::class.java).sortedBy(rendered::getSpanStart)
            assertEquals(2, tables.size)
            assertEquals(listOf(listOf("名称", "值"), listOf("粗体", "链接")), tables[0].table.plainRows)
            assertEquals("转义|竖线", tables[1].table.plainRows[1][0])
            assertTrue(MarkdownTableExport.csv(tables[1].table.plainRows).contains("\"x,y\""))
            assertTrue(rendered.toString().contains("之后"))
        }
    }

    private fun descendants(view: View): List<View> = listOf(view) +
        if (view is ViewGroup) (0 until view.childCount).flatMap { descendants(view.getChildAt(it)) } else emptyList()

    private fun dshTestPalette() = DshMarkdownPalette(0xFF10131A.toInt(), 0xFF007AFF.toInt(), 0x3310131A, 0x1410131A,
        0x0910131A, 0x7310131A, 1, 8, 0xFFE9E9ED.toInt(), 6f, 4f, 1f)
}
